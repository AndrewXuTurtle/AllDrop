import Foundation
import Network
import CryptoKit

typealias OfflineFrame = Location_Nearby_Connections_OfflineFrame
typealias PayloadTransferFrame = Location_Nearby_Connections_PayloadTransferFrame
typealias SharingFrame = Sharing_Nearby_Frame

/// Shared plumbing for both directions: length-prefixed TCP framing, the UKEY2-derived
/// secure channel, keep-alives, and reassembly of BYTES payloads.
///
/// Every method runs on `QuickShareService.queue`; subclasses must not touch state from elsewhere.
class NearbyConnection {
    static let maxFrameLength = 5 * 1024 * 1024
    static let keepAliveInterval: DispatchTimeInterval = .seconds(10)

    let id: String
    let connection: NWConnection
    let queue: DispatchQueue

    var channel: SecureChannel?
    /// The two directions switch to encryption at different points of the handshake.
    var encryptOutgoing = false
    var decryptIncoming = false
    var privateKey = P256.KeyAgreement.PrivateKey()
    var ukeyClientInit: Data?
    var ukeyServerInit: Data?
    var lastError: Error?
    private(set) var isClosed = false

    private var byteBuffers: [Int64: Data] = [:]
    private var keepAliveTimer: DispatchSourceTimer?
    private var closeReported = false

    var isServer: Bool { fatalError("override") }
    var pin: String? { channel?.keys.pin }

    init(id: String, connection: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectionReady()
                self.receiveLength()
            case .failed(let error):
                self.lastError = self.lastError ?? error
                self.connection.cancel()
                self.finish()
            case .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: Subclass hooks

    func connectionReady() {}
    /// A frame that arrived before encryption was set up.
    func handlePlaintextFrame(_ data: Data) throws { fatalError("override") }
    /// A Nearby Share protocol message, carried inside a BYTES payload.
    func handleSharingFrame(_ frame: SharingFrame) throws {}
    func handleFileChunk(_ transfer: PayloadTransferFrame) throws {
        throw QuickShareError.protocolViolation("unexpected file payload")
    }
    /// Return true if the payload was consumed; otherwise it is parsed as a sharing frame.
    func handleBytesPayload(_ data: Data, id: Int64) throws -> Bool { false }
    /// Called exactly once, after the connection has gone away for any reason.
    func didClose() {}

    // MARK: Receiving

    private func receiveLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error { return self.fail(error) }
            guard let content, content.count == 4 else {
                return isComplete ? self.close() : self.fail(QuickShareError.connectionLost)
            }
            let length = content.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= Self.maxFrameLength else {
                return self.fail(QuickShareError.protocolViolation("frame length \(length)"))
            }
            self.receiveFrame(length: length)
        }
    }

    private func receiveFrame(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] content, _, _, error in
            guard let self, !self.isClosed else { return }
            if let error { return self.fail(error) }
            guard let content, content.count == length else { return self.fail(QuickShareError.connectionLost) }
            do {
                if !self.decryptIncoming {
                    try self.handlePlaintextFrame(content)
                } else {
                    try self.handleEncryptedFrame(content)
                }
            } catch {
                return self.fail(error)
            }
            if !self.isClosed { self.receiveLength() }
        }
    }

    private func handleEncryptedFrame(_ data: Data) throws {
        guard var channel else { return }
        let frame = try channel.open(data)
        self.channel = channel
        guard frame.hasV1 else { return }

        switch frame.v1.type {
        case .payloadTransfer:
            let transfer = frame.v1.payloadTransfer
            switch transfer.payloadHeader.type {
            case .bytes: try handleBytesChunk(transfer)
            case .file: try handleFileChunk(transfer)
            default: break
            }
        case .keepAlive:
            if !frame.v1.keepAlive.ack { sendKeepAlive(ack: true) }
        case .disconnection:
            close()
        default:
            break
        }
    }

    private func handleBytesChunk(_ transfer: PayloadTransferFrame) throws {
        let header = transfer.payloadHeader
        let chunk = transfer.payloadChunk
        guard header.totalSize <= Self.maxFrameLength else {
            throw QuickShareError.protocolViolation("bytes payload of \(header.totalSize) bytes")
        }
        var buffer = byteBuffers[header.id] ?? Data()
        guard chunk.offset == buffer.count else {
            throw QuickShareError.protocolViolation("chunk offset \(chunk.offset), expected \(buffer.count)")
        }
        buffer.append(chunk.body)
        guard chunk.flags & 1 == 1 else {
            byteBuffers[header.id] = buffer
            return
        }
        byteBuffers[header.id] = nil
        if try !handleBytesPayload(buffer, id: header.id) {
            try handleSharingFrame(try SharingFrame(serializedBytes: buffer))
        }
    }

    // MARK: Sending

    func sendRaw(_ data: Data, completion: (() -> Void)? = nil) {
        guard !isClosed else { return }
        var framed = Data(capacity: data.count + 4)
        let length = UInt32(data.count)
        framed.append(contentsOf: [UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF),
                                   UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        framed.append(data)
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error) } else { completion?() }
        })
    }

    func sendOfflineFrame(_ frame: OfflineFrame, completion: (() -> Void)? = nil) throws {
        if encryptOutgoing, var channel {
            let sealed = try channel.seal(frame)
            self.channel = channel
            sendRaw(sealed, completion: completion)
        } else {
            sendRaw(try frame.serializedData(), completion: completion)
        }
    }

    /// Sends a sharing frame the way Android does: one chunk with everything, then an empty LAST_CHUNK.
    func sendSharingFrame(_ frame: SharingFrame) throws {
        try sendBytesPayload(try frame.serializedData(), id: .randomPayloadID())
    }

    func sendBytesPayload(_ data: Data, id: Int64) throws {
        var transfer = PayloadTransferFrame()
        transfer.packetType = .data
        transfer.payloadHeader.id = id
        transfer.payloadHeader.type = .bytes
        transfer.payloadHeader.totalSize = Int64(data.count)
        transfer.payloadHeader.isSensitive = false
        transfer.payloadChunk.offset = 0
        transfer.payloadChunk.flags = 0
        transfer.payloadChunk.body = data
        try sendOfflineFrame(.payloadTransfer(transfer))

        transfer.payloadChunk.offset = Int64(data.count)
        transfer.payloadChunk.flags = 1
        transfer.payloadChunk.clearBody()
        try sendOfflineFrame(.payloadTransfer(transfer))
    }

    func sendKeepAlive(ack: Bool) {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .keepAlive
        frame.v1.keepAlive.ack = ack
        try? sendOfflineFrame(frame)
    }

    func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.keepAliveInterval, repeating: Self.keepAliveInterval)
        timer.setEventHandler { [weak self] in self?.sendKeepAlive(ack: false) }
        timer.resume()
        keepAliveTimer = timer
    }

    static func connectionResponse() -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .connectionResponse
        frame.v1.connectionResponse.response = .accept
        frame.v1.connectionResponse.status = 0
        frame.v1.connectionResponse.osInfo.type = .apple
        return frame
    }

    static func pairedKeyEncryption(qrHandshake: Data? = nil) -> SharingFrame {
        var frame = SharingFrame()
        frame.version = .v1
        frame.v1.type = .pairedKeyEncryption
        // These would prove contact-based identity via Google's servers; random values work in "Everyone" mode.
        frame.v1.pairedKeyEncryption.secretIDHash = .random(6)
        frame.v1.pairedKeyEncryption.signedData = .random(72)
        if let qrHandshake { frame.v1.pairedKeyEncryption.qrCodeHandshakeData = qrHandshake }
        return frame
    }

    static func pairedKeyResult() -> SharingFrame {
        var frame = SharingFrame()
        frame.version = .v1
        frame.v1.type = .pairedKeyResult
        frame.v1.pairedKeyResult.status = .unable
        return frame
    }

    // MARK: Key exchange

    func deriveKeys(peerKey: P256.KeyAgreement.PublicKey) throws {
        guard let ukeyClientInit, let ukeyServerInit else { throw QuickShareError.ukey2("handshake incomplete") }
        let keys = try SessionKeys(privateKey: privateKey, peerKey: peerKey,
                                   clientInit: ukeyClientInit, serverInit: ukeyServerInit, isServer: isServer)
        channel = SecureChannel(keys: keys)
    }

    func sendUkey2Alert(_ type: Securegcm_Ukey2Alert.AlertType, _ message: String) -> Error {
        var alert = Securegcm_Ukey2Alert()
        alert.type = type
        if let body = try? alert.serializedData(), let data = try? UKEY2.message(.alert, body) {
            sendRaw(data)
        }
        return QuickShareError.ukey2(message)
    }

    // MARK: Teardown

    func fail(_ error: Error) {
        guard !isClosed else { return }
        lastError = lastError ?? error
        close()
    }

    /// Politely tells the peer we're done, then closes.
    func disconnect() {
        guard !isClosed else { return }
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .disconnection
        try? sendOfflineFrame(frame)
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // Half-close so queued sends (like the last file chunk) still flush, then tear down.
        let connection = self.connection
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        finish()
    }

    private func finish() {
        isClosed = true
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        guard !closeReported else { return }
        closeReported = true
        didClose()
    }
}

extension OfflineFrame {
    static func payloadTransfer(_ transfer: PayloadTransferFrame) -> OfflineFrame {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .payloadTransfer
        frame.v1.payloadTransfer = transfer
        return frame
    }
}
