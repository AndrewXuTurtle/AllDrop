import Foundation
import Network
import CryptoKit

protocol InboundConnectionDelegate: AnyObject {
    func inbound(_ connection: InboundConnection, needsConsentFor request: IncomingRequest)
    func inbound(_ connection: InboundConnection, progress: Double)
    func inbound(_ connection: InboundConnection, finishedWith result: Result<[ReceivedItem], Error>)
    func inboundDidClose(_ connection: InboundConnection)
}

/// We are the server: a phone connected to our advertised port to send us something.
final class InboundConnection: NearbyConnection {
    private enum State {
        case awaitingConnectionRequest, awaitingClientInit, awaitingClientFinish, awaitingConnectionResponse
        case negotiating, awaitingConsent, receiving, done
    }

    private struct FileState {
        let meta: IncomingFile
        let url: URL
        var handle: FileHandle?
        var written: Int64 = 0
    }

    weak var delegate: InboundConnectionDelegate?
    private let destination: URL
    private var state = State.awaitingConnectionRequest
    private var clientFinishCommitment: Data?
    private var senderName = "Unknown device"
    private var senderType = DeviceType.unknown
    private var files: [Int64: FileState] = [:]
    private var textPayload: (id: Int64, isURL: Bool)?
    private var received: [ReceivedItem] = []
    private var totalBytes: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var requestSurfaced = false

    override var isServer: Bool { true }

    init(id: String, connection: NWConnection, queue: DispatchQueue, destination: URL) {
        self.destination = destination
        super.init(id: id, connection: connection, queue: queue)
    }

    // MARK: Handshake

    override func handlePlaintextFrame(_ data: Data) throws {
        switch state {
        case .awaitingConnectionRequest:
            let frame = try OfflineFrame(serializedBytes: data)
            guard frame.v1.type == .connectionRequest else {
                throw QuickShareError.protocolViolation("expected connection request, got \(frame.v1.type)")
            }
            let request = frame.v1.connectionRequest
            if let info = EndpointInfo(request.endpointInfo) {
                senderType = info.deviceType
                senderName = info.name ?? request.endpointName
            } else if !request.endpointName.isEmpty {
                senderName = request.endpointName
            }
            state = .awaitingClientInit

        case .awaitingClientInit:
            try handleClientInit(data)

        case .awaitingClientFinish:
            let message = try Securegcm_Ukey2Message(serializedBytes: data)
            guard message.messageType == .clientFinish else {
                throw sendUkey2Alert(.badMessageType, "expected ClientFinished")
            }
            guard Data(SHA512.hash(data: data)) == clientFinishCommitment else {
                throw QuickShareError.ukey2("ClientFinished does not match commitment")
            }
            let finish = try Securegcm_Ukey2ClientFinished(serializedBytes: message.messageData)
            let peerKey = try UKEY2.decode(finish.publicKey)
            try deriveKeys(peerKey: peerKey)
            state = .awaitingConnectionResponse

        case .awaitingConnectionResponse:
            let frame = try OfflineFrame(serializedBytes: data)
            guard frame.v1.type == .connectionResponse else { return }
            guard frame.v1.connectionResponse.response == .accept else { return close() }
            try sendOfflineFrame(Self.connectionResponse())
            startEncryption()
            startKeepAlive()
            state = .negotiating
            try sendSharingFrame(Self.pairedKeyEncryption())

        default:
            throw QuickShareError.protocolViolation("unexpected plaintext frame")
        }
    }

    private func handleClientInit(_ data: Data) throws {
        let message = try Securegcm_Ukey2Message(serializedBytes: data)
        guard message.messageType == .clientInit else { throw sendUkey2Alert(.badMessageType, "expected ClientInit") }
        guard let clientInit = try? Securegcm_Ukey2ClientInit(serializedBytes: message.messageData) else {
            throw sendUkey2Alert(.badMessageData, "unreadable ClientInit")
        }
        guard clientInit.version == 1 else { throw sendUkey2Alert(.badVersion, "version \(clientInit.version)") }
        guard clientInit.random.count == 32 else { throw sendUkey2Alert(.badRandom, "bad random") }
        guard let commitment = clientInit.cipherCommitments.first(where: { $0.handshakeCipher == .p256Sha512 }) else {
            throw sendUkey2Alert(.badHandshakeCipher, "no P256_SHA512 commitment")
        }
        guard clientInit.nextProtocol == UKEY2.nextProtocol else {
            throw sendUkey2Alert(.badNextProtocol, "next protocol \(clientInit.nextProtocol)")
        }
        clientFinishCommitment = commitment.commitment
        ukeyClientInit = data

        var serverInit = Securegcm_Ukey2ServerInit()
        serverInit.version = 1
        serverInit.random = .random(32)
        serverInit.handshakeCipher = .p256Sha512
        serverInit.publicKey = try UKEY2.encode(privateKey.publicKey)
        let raw = try UKEY2.message(.serverInit, try serverInit.serializedData())
        ukeyServerInit = raw
        sendRaw(raw)
        state = .awaitingClientFinish
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
            break
        case .introduction where state == .negotiating:
            try handleIntroduction(frame.v1.introduction)
        default:
            break
        }
    }

    private func handleIntroduction(_ intro: Sharing_Nearby_IntroductionFrame) throws {
        let content: IncomingContent
        if !intro.fileMetadata.isEmpty {
            var reserved = Set<String>()
            for meta in intro.fileMetadata {
                let url = Self.uniqueDestination(in: destination, for: meta.name, avoiding: &reserved)
                let file = IncomingFile(name: url.lastPathComponent, size: meta.size, mimeType: meta.mimeType)
                files[meta.payloadID] = FileState(meta: file, url: url)
                totalBytes += max(meta.size, 0)
            }
            content = .files(files.values.map(\.meta).sorted { $0.name < $1.name })
        } else if intro.textMetadata.count == 1 {
            let meta = intro.textMetadata[0]
            let isURL = meta.type == .url
            textPayload = (meta.payloadID, isURL)
            totalBytes = max(meta.size, 0)
            content = isURL ? .url(title: meta.textTitle) : .text(size: meta.size)
        } else {
            return try reject(.unsupportedAttachmentType)
        }

        state = .awaitingConsent
        requestSurfaced = true
        let request = IncomingRequest(id: id, senderName: senderName, senderType: senderType,
                                      pin: pin ?? "----", content: content)
        delegate?.inbound(self, needsConsentFor: request)
    }

    func respond(accept: Bool) {
        guard state == .awaitingConsent else { return }
        do {
            guard accept else {
                lastError = QuickShareError.rejected
                return try reject(.reject)
            }
            for (id, file) in files {
                guard FileManager.default.createFile(atPath: file.url.path, contents: nil) else {
                    throw QuickShareError.io("can't create \(file.url.path)")
                }
                files[id]?.handle = try FileHandle(forWritingTo: file.url)
            }
            var frame = SharingFrame()
            frame.version = .v1
            frame.v1.type = .response
            frame.v1.connectionResponse.status = .accept
            state = .receiving
            try sendSharingFrame(frame)
        } catch {
            fail(error)
        }
    }

    private func reject(_ status: Sharing_Nearby_ConnectionResponseFrame.Status) throws {
        var frame = SharingFrame()
        frame.version = .v1
        frame.v1.type = .response
        frame.v1.connectionResponse.status = status
        try sendSharingFrame(frame)
        disconnect()
    }

    // MARK: Receiving data

    override func handleFileChunk(_ transfer: PayloadTransferFrame) throws {
        guard state == .receiving else { throw QuickShareError.protocolViolation("file data before acceptance") }
        let id = transfer.payloadHeader.id
        guard var file = files[id] else { throw QuickShareError.protocolViolation("unknown file payload \(id)") }
        let chunk = transfer.payloadChunk
        guard chunk.offset == file.written else {
            throw QuickShareError.protocolViolation("file offset \(chunk.offset), expected \(file.written)")
        }
        guard file.written + Int64(chunk.body.count) <= file.meta.size else {
            throw QuickShareError.protocolViolation("file is larger than announced")
        }
        if !chunk.body.isEmpty {
            try file.handle?.write(contentsOf: chunk.body)
            file.written += Int64(chunk.body.count)
            receivedBytes += Int64(chunk.body.count)
            reportProgress()
        }
        files[id] = file
        if chunk.flags & 1 == 1 { try completeFile(id) }
    }

    override func handleBytesPayload(_ data: Data, id: Int64) throws -> Bool {
        if let text = textPayload, text.id == id {
            guard state == .receiving else { throw QuickShareError.protocolViolation("text before acceptance") }
            let string = String(decoding: data, as: UTF8.self)
            if text.isURL, let url = URL(string: string) {
                received.append(.url(url))
            } else {
                received.append(.text(string))
            }
            textPayload = nil
            finishIfDone()
            return true
        }
        if var file = files[id], state == .receiving {
            // Tiny files sometimes arrive as a BYTES payload instead of FILE.
            try file.handle?.write(contentsOf: data)
            file.written = Int64(data.count)
            receivedBytes += Int64(data.count)
            files[id] = file
            try completeFile(id)
            return true
        }
        return false
    }

    private func completeFile(_ id: Int64) throws {
        guard let file = files.removeValue(forKey: id) else { return }
        try file.handle?.close()
        received.append(.file(file.url))
        finishIfDone()
    }

    private func finishIfDone() {
        guard files.isEmpty, textPayload == nil else { return }
        state = .done
        reportProgress()
        disconnect()
    }

    private func reportProgress() {
        guard totalBytes > 0 else { return }
        delegate?.inbound(self, progress: Double(receivedBytes) / Double(totalBytes))
    }

    override func didClose() {
        defer { delegate?.inboundDidClose(self) }
        if state == .done {
            delegate?.inbound(self, finishedWith: .success(received))
            return
        }
        // Clean up anything half-written.
        for file in files.values where file.handle != nil {
            try? file.handle?.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        files.removeAll()
        if requestSurfaced {
            delegate?.inbound(self, finishedWith: .failure(lastError ?? QuickShareError.connectionLost))
        }
    }

    // MARK: Helpers

    private func startEncryption() {
        // Both directions are encrypted from here on.
        encryptOutgoing = true
        decryptIncoming = true
    }

    /// Picks a file name in `directory` that doesn't exist yet. The sender controls `name`, so path
    /// components are stripped to keep writes inside `directory`.
    static func uniqueDestination(in directory: URL, for name: String, avoiding reserved: inout Set<String>) -> URL {
        var base = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Received file" }

        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var candidate = base
        var counter = 1
        while reserved.contains(candidate)
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        reserved.insert(candidate)
        return directory.appendingPathComponent(candidate)
    }
}
