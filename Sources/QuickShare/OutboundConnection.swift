import Foundation
import Network
import CryptoKit
import UniformTypeIdentifiers

/// We are the client: we connected to a receiver's advertised port to send it something.
final class OutboundConnection: NearbyConnection {
    private enum State {
        case connecting, awaitingServerInit, awaitingConnectionResponse, negotiating, awaitingConsent, sending, done
    }

    private struct OutgoingFile {
        let url: URL
        let payloadID: Int64
        let size: Int64
        var handle: FileHandle?
        var offset: Int64 = 0
    }

    static let chunkSize = 512 * 1024

    var onEvent: ((OutgoingEvent) -> Void)?
    private let content: OutgoingContent
    private let localEndpointID: String
    private let localName: String
    private let qrSigningKey: P256.Signing.PrivateKey?
    private var state = State.connecting
    private var ukeyClientFinish: Data?
    private var introductionSent = false
    private var queuedFiles: [OutgoingFile] = []
    private var currentFile: OutgoingFile?
    private var textPayloadID = Int64.randomPayloadID()
    private var totalBytes: Int64 = 0
    private var sentBytes: Int64 = 0

    override var isServer: Bool { false }

    init(id: String, connection: NWConnection, queue: DispatchQueue, content: OutgoingContent,
         localEndpointID: String, localName: String, qrSigningKey: P256.Signing.PrivateKey?) {
        self.content = content
        self.localEndpointID = localEndpointID
        self.localName = localName
        self.qrSigningKey = qrSigningKey
        super.init(id: id, connection: connection, queue: queue)
    }

    func cancel() {
        guard !isClosed else { return }
        lastError = QuickShareError.cancelled
        if encryptOutgoing {
            var frame = SharingFrame()
            frame.version = .v1
            frame.v1.type = .cancel
            try? sendSharingFrame(frame)
        }
        disconnect()
    }

    // MARK: Handshake

    override func connectionReady() {
        do {
            var request = OfflineFrame()
            request.version = .v1
            request.v1.type = .connectionRequest
            request.v1.connectionRequest.endpointID = localEndpointID
            request.v1.connectionRequest.endpointName = localName
            request.v1.connectionRequest.endpointInfo = EndpointInfo(name: localName, deviceType: .laptop).serialized()
            request.v1.connectionRequest.mediums = [.wifiLan]
            try sendOfflineFrame(request)

            // UKEY2 commits to ClientFinished up front, so build it first.
            var finish = Securegcm_Ukey2ClientFinished()
            finish.publicKey = try UKEY2.encode(privateKey.publicKey)
            let finishRaw = try UKEY2.message(.clientFinish, try finish.serializedData())
            ukeyClientFinish = finishRaw

            var commitment = Securegcm_Ukey2ClientInit.CipherCommitment()
            commitment.handshakeCipher = .p256Sha512
            commitment.commitment = Data(SHA512.hash(data: finishRaw))
            var clientInit = Securegcm_Ukey2ClientInit()
            clientInit.version = 1
            clientInit.random = .random(32)
            clientInit.nextProtocol = UKEY2.nextProtocol
            clientInit.cipherCommitments = [commitment]
            let initRaw = try UKEY2.message(.clientInit, try clientInit.serializedData())
            ukeyClientInit = initRaw
            sendRaw(initRaw)
            state = .awaitingServerInit
            onEvent?(.connecting)
        } catch {
            fail(error)
        }
    }

    override func handlePlaintextFrame(_ data: Data) throws {
        switch state {
        case .awaitingServerInit:
            let message = try Securegcm_Ukey2Message(serializedBytes: data)
            if message.messageType == .alert {
                throw QuickShareError.ukey2("receiver sent an alert")
            }
            guard message.messageType == .serverInit else { throw sendUkey2Alert(.badMessageType, "expected ServerInit") }
            let serverInit = try Securegcm_Ukey2ServerInit(serializedBytes: message.messageData)
            guard serverInit.version == 1 else { throw sendUkey2Alert(.badVersion, "version \(serverInit.version)") }
            guard serverInit.random.count == 32 else { throw sendUkey2Alert(.badRandom, "bad random") }
            guard serverInit.handshakeCipher == .p256Sha512 else {
                throw sendUkey2Alert(.badHandshakeCipher, "cipher \(serverInit.handshakeCipher)")
            }
            ukeyServerInit = data
            try deriveKeys(peerKey: try UKEY2.decode(serverInit.publicKey))
            sendRaw(ukeyClientFinish!)
            try sendOfflineFrame(Self.connectionResponse())
            encryptOutgoing = true
            state = .awaitingConnectionResponse

        case .awaitingConnectionResponse:
            let frame = try OfflineFrame(serializedBytes: data)
            guard frame.v1.type == .connectionResponse else {
                throw QuickShareError.protocolViolation("expected connection response, got \(frame.v1.type)")
            }
            guard frame.v1.connectionResponse.response == .accept else { throw QuickShareError.rejected }
            decryptIncoming = true
            state = .negotiating
            startKeepAlive()

            // Signing the auth string with the QR key lets the receiver skip its own Accept prompt.
            let qrHandshake = try qrSigningKey.map { key in
                try key.signature(for: channel!.keys.authString).rawRepresentation
            }
            try sendSharingFrame(Self.pairedKeyEncryption(qrHandshake: qrHandshake))

        default:
            throw QuickShareError.protocolViolation("unexpected plaintext frame")
        }
    }

    // MARK: Transfer setup

    override func handleSharingFrame(_ frame: SharingFrame) throws {
        switch frame.v1.type {
        case .cancel:
            lastError = QuickShareError.cancelled
            close()
        case .pairedKeyEncryption:
            try sendSharingFrame(Self.pairedKeyResult())
        case .pairedKeyResult:
            try sendIntroduction()
        case .response where state == .awaitingConsent:
            try handleConsent(frame.v1.connectionResponse.status)
        default:
            break
        }
    }

    private func sendIntroduction() throws {
        guard !introductionSent else { return }
        introductionSent = true

        var frame = SharingFrame()
        frame.version = .v1
        frame.v1.type = .introduction
        switch content {
        case .files(let urls):
            for url in urls {
                let size = try Self.fileSize(url)
                var meta = Sharing_Nearby_FileMetadata()
                meta.name = Self.sanitize(url.lastPathComponent)
                meta.size = size
                meta.mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                meta.type = Self.fileType(mime: meta.mimeType, ext: url.pathExtension)
                meta.payloadID = .randomPayloadID()
                frame.v1.introduction.fileMetadata.append(meta)
                queuedFiles.append(OutgoingFile(url: url, payloadID: meta.payloadID, size: size))
                totalBytes += size
            }
        case .text(let text):
            var meta = Sharing_Nearby_TextMetadata()
            meta.type = .text
            meta.textTitle = String(text.prefix(40))
            meta.size = Int64(text.utf8.count)
            meta.payloadID = textPayloadID
            frame.v1.introduction.textMetadata = [meta]
        case .url(let url):
            var meta = Sharing_Nearby_TextMetadata()
            meta.type = .url
            meta.textTitle = url.host ?? url.absoluteString
            meta.size = Int64(url.absoluteString.utf8.count)
            meta.payloadID = textPayloadID
            frame.v1.introduction.textMetadata = [meta]
        }
        try sendSharingFrame(frame)
        state = .awaitingConsent
        onEvent?(.awaitingAcceptance(pin: pin ?? "----"))
    }

    private func handleConsent(_ status: Sharing_Nearby_ConnectionResponseFrame.Status) throws {
        switch status {
        case .accept:
            state = .sending
            onEvent?(.sending(progress: 0))
            switch content {
            case .files:
                try sendNextChunk()
            case .text(let text):
                try sendBytesPayload(Data(text.utf8), id: textPayloadID)
                complete()
            case .url(let url):
                try sendBytesPayload(Data(url.absoluteString.utf8), id: textPayloadID)
                complete()
            }
        case .notEnoughSpace:
            throw QuickShareError.notEnoughSpace
        case .unsupportedAttachmentType:
            throw QuickShareError.unsupportedType
        case .timedOut:
            throw QuickShareError.timedOut
        default:
            throw QuickShareError.rejected
        }
    }

    // MARK: Sending data

    /// Sends one chunk and schedules the next from the send completion, so we never buffer more than a chunk.
    private func sendNextChunk() throws {
        guard !isClosed else { return }
        if currentFile == nil {
            guard !queuedFiles.isEmpty else { return complete() }
            var next = queuedFiles.removeFirst()
            do {
                next.handle = try FileHandle(forReadingFrom: next.url)
            } catch {
                throw QuickShareError.io("can't read \(next.url.lastPathComponent)")
            }
            currentFile = next
        }
        guard var file = currentFile else { return }

        let data = try file.handle?.read(upToCount: Self.chunkSize) ?? Data()
        let continueSending: () -> Void = { [weak self] in
            guard let self else { return }
            do { try self.sendNextChunk() } catch { self.fail(error) }
        }

        var transfer = PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader.id = file.payloadID
        transfer.payloadHeader.type = .file
        transfer.payloadHeader.totalSize = file.size
        transfer.payloadHeader.isSensitive = false

        if !data.isEmpty {
            transfer.payloadChunk.offset = file.offset
            transfer.payloadChunk.flags = 0
            transfer.payloadChunk.body = data
            file.offset += Int64(data.count)
            sentBytes += Int64(data.count)
            currentFile = file
            let atEnd = file.offset >= file.size
            try sendOfflineFrame(.payloadTransfer(transfer), completion: atEnd ? nil : continueSending)
            onEvent?(.sending(progress: totalBytes > 0 ? Double(sentBytes) / Double(totalBytes) : 1))
            guard atEnd else { return }
        }

        // End of file: an empty chunk with the LAST_CHUNK flag.
        transfer.payloadChunk.offset = file.offset
        transfer.payloadChunk.flags = 1
        transfer.payloadChunk.clearBody()
        try? file.handle?.close()
        currentFile = nil
        try sendOfflineFrame(.payloadTransfer(transfer), completion: continueSending)
    }

    private func complete() {
        guard state != .done else { return }
        state = .done
        onEvent?(.completed)
        disconnect()
    }

    override func didClose() {
        try? currentFile?.handle?.close()
        if state != .done {
            onEvent?(.failed(lastError ?? QuickShareError.connectionLost))
        }
        onEvent = nil
    }

    // MARK: Helpers

    private static func fileSize(_ url: URL) throws -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw QuickShareError.io("can't read \(url.lastPathComponent)")
        }
        return Int64(size)
    }

    private static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "[\\\\/?%*:|\"<>=]", with: "_", options: .regularExpression)
    }

    private static func fileType(mime: String, ext: String) -> Sharing_Nearby_FileMetadata.TypeEnum {
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        if ext.lowercased() == "apk" { return .androidApp }
        return .unknown
    }
}
