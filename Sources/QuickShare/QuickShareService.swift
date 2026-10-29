import Foundation
import Network
import CryptoKit

/// All callbacks arrive on the main queue.
public protocol QuickShareServiceDelegate: AnyObject {
    func quickShare(_ service: QuickShareService, didReceive request: IncomingRequest)
    func quickShare(_ service: QuickShareService, incomingTransfer id: String, progress: Double)
    func quickShare(_ service: QuickShareService, incomingTransfer id: String, finishedWith result: Result<[ReceivedItem], Error>)
    func quickShare(_ service: QuickShareService, didUpdateNearbyDevices devices: [RemoteDevice])
    /// A device scanned the QR code from `startQRCodeSession()` and is now waiting for us to send.
    func quickShare(_ service: QuickShareService, qrCodeScannedBy device: RemoteDevice)
}

/// Speaks Google/Samsung Quick Share over the local Wi-Fi network.
///
/// Receiving: we advertise an mDNS service that phones show in their Quick Share sheet.
/// Sending: phones only advertise themselves after hearing a BLE beacon macOS can't emit,
/// so we show a QR code; scanning it makes the phone advertise, and we connect.
public final class QuickShareService: @unchecked Sendable {
    static let serviceType = "_FC9F5ED42C8A._tcp"
    /// First three bytes of SHA256("NearbySharing").
    static let serviceIDHash: [UInt8] = [0xFC, 0x9F, 0x5E]

    public weak var delegate: QuickShareServiceDelegate?
    public var deviceName: String
    public var downloadsDirectory: URL
    public let endpointID: String

    let queue = DispatchQueue(label: "QuickShare", qos: .userInitiated)
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var inbound: [String: InboundConnection] = [:]
    private var outbound: [String: OutboundConnection] = [:]
    private var discovered: [String: (device: RemoteDevice, endpoint: NWEndpoint)] = [:]
    private var qrSession: QRSession?

    struct QRSession {
        let signingKey: P256.Signing.PrivateKey
        let keyData: Data
        let advertisingToken: Data
        let nameKey: SymmetricKey
        var matched: Set<String> = []

        init() {
            var key = P256.Signing.PrivateKey()
            // The QR format carries a compressed point whose prefix Android may read either as a version
            // or as Y parity; an even-Y key (prefix 0x02) means the same thing under both readings.
            while key.publicKey.compressedRepresentation.first != 0x02 { key = P256.Signing.PrivateKey() }
            signingKey = key
            keyData = Data([0, 0]) + key.publicKey.compressedRepresentation
            let ikm = SymmetricKey(data: keyData)
            advertisingToken = SessionKeys.hkdf(ikm, salt: Data(), info: Data("advertisingContext".utf8), length: 16)
                .withUnsafeBytes { Data($0) }
            nameKey = SessionKeys.hkdf(ikm, salt: Data(), info: Data("encryptionKey".utf8), length: 16)
        }

        var url: URL { URL(string: "https://quickshare.google/qrcode#key=\(keyData.urlSafeBase64)")! }

        enum Match: Equatable { case none, visible, hidden(name: String) }

        /// Checks the QR TLV a receiver advertises: visible devices echo the advertising token,
        /// hidden ones send their name AES-GCM encrypted with a key derived from the QR code.
        func match(_ qrData: Data) -> Match {
            if qrData == advertisingToken { return .visible }
            guard qrData.count > 28,
                  let box = try? AES.GCM.SealedBox(combined: qrData),
                  let plain = try? AES.GCM.open(box, using: nameKey, authenticating: advertisingToken)
            else { return .none }
            return .hidden(name: String(decoding: plain, as: UTF8.self))
        }
    }

    public init(deviceName: String = Host.current().localizedName ?? "Mac",
                downloadsDirectory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) {
        self.deviceName = deviceName
        self.downloadsDirectory = downloadsDirectory
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        endpointID = String((0..<4).map { _ in alphabet.randomElement()! })
    }

    // MARK: Receiving

    /// Starts listening and advertising so phones on this network see the Mac in Quick Share.
    public func startReceiving() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)

        var nameBytes: [UInt8] = [0x23] // "PCP"
        nameBytes += Array(endpointID.utf8)
        nameBytes += Self.serviceIDHash
        nameBytes += [0, 0]
        var txt = NWTXTRecord()
        txt["n"] = EndpointInfo(name: deviceName, deviceType: .laptop).serialized().urlSafeBase64
        listener.service = NWListener.Service(name: Data(nameBytes).urlSafeBase64, type: Self.serviceType,
                                              domain: nil, txtRecord: txt)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let id = UUID().uuidString
            let inbound = InboundConnection(id: id, connection: connection, queue: self.queue,
                                            destination: self.downloadsDirectory)
            inbound.delegate = self
            self.inbound[id] = inbound
            inbound.start()
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { NSLog("QuickShare listener failed: \(error)") }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stopReceiving() {
        listener?.cancel()
        listener = nil
    }

    public func respond(to requestID: String, accept: Bool) {
        queue.async { self.inbound[requestID]?.respond(accept: accept) }
    }

    // MARK: Discovery

    public func startDiscovery() {
        queue.async { [self] in
            guard browser == nil else { return }
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.updateDiscovered(results) }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    public func stopDiscovery() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            discovered.removeAll()
            notifyDevices()
        }
    }

    /// Returns the URL to show as a QR code. While the session is active, discovery also watches
    /// for the phone that scanned it.
    public func startQRCodeSession() -> URL {
        let session = QRSession()
        queue.sync { qrSession = session }
        startDiscovery()
        return session.url
    }

    public func endQRCodeSession() {
        queue.async { self.qrSession = nil }
    }

    private func updateDiscovered(_ results: Set<NWBrowser.Result>) {
        var found: [String: (device: RemoteDevice, endpoint: NWEndpoint)] = [:]
        var scanned: [RemoteDevice] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  let nameData = Data(urlSafeBase64: name), nameData.count >= 10,
                  nameData[0] == 0x23, Array(nameData[5..<8]) == Self.serviceIDHash,
                  let id = String(data: nameData[1..<5], encoding: .ascii), id != endpointID,
                  case let .bonjour(txt) = result.metadata,
                  let encoded = txt["n"], let raw = Data(urlSafeBase64: encoded),
                  var info = EndpointInfo(raw)
            else { continue }
            if result.interfaces.contains(where: { $0.type == .loopback }) { continue }

            var matchedQR = false
            if let qr = info.qrCodeData, let session = qrSession {
                switch session.match(qr) {
                case .none: break
                case .visible: matchedQR = true
                case .hidden(let name):
                    info.name = name
                    matchedQR = true
                }
            }
            guard let name = info.name else { continue }
            let device = RemoteDevice(id: id, name: name, type: info.deviceType)
            found[id] = (device, result.endpoint)
            if matchedQR, qrSession?.matched.insert(id).inserted == true { scanned.append(device) }
        }
        discovered = found
        notifyDevices()
        for device in scanned {
            DispatchQueue.main.async { self.delegate?.quickShare(self, qrCodeScannedBy: device) }
        }
    }

    private func notifyDevices() {
        let devices = discovered.values.map(\.device).sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.delegate?.quickShare(self, didUpdateNearbyDevices: devices) }
    }

    // MARK: Sending

    /// Sends to a discovered device. Events arrive on the main queue. Returns an ID for `cancelSend`.
    @discardableResult
    public func send(_ content: OutgoingContent, to device: RemoteDevice,
                     events: @escaping @MainActor (OutgoingEvent) -> Void) -> String {
        let transferID = UUID().uuidString
        queue.async { [self] in
            guard let endpoint = discovered[device.id]?.endpoint else {
                return DispatchQueue.main.async { MainActor.assumeIsolated { events(.failed(QuickShareError.connectionLost)) } }
            }
            send(content, to: endpoint, transferID: transferID, events: events)
        }
        return transferID
    }

    /// Sends straight to a host and port, bypassing discovery (useful for testing).
    func send(_ content: OutgoingContent, to endpoint: NWEndpoint, transferID: String,
              events: @escaping @MainActor (OutgoingEvent) -> Void) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        let outbound = OutboundConnection(id: transferID, connection: connection, queue: queue, content: content,
                                          localEndpointID: endpointID, localName: deviceName,
                                          qrSigningKey: qrSession?.signingKey)
        outbound.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { events(event) } }
            switch event {
            case .completed, .failed: self?.outbound[transferID] = nil
            default: break
            }
        }
        self.outbound[transferID] = outbound
        outbound.start()
    }

    public func cancelSend(_ transferID: String) {
        queue.async { self.outbound[transferID]?.cancel() }
    }

    /// The port we're listening on, once ready.
    var listeningPort: UInt16? { listener?.port?.rawValue }
}

extension QuickShareService: InboundConnectionDelegate {
    func inbound(_ connection: InboundConnection, needsConsentFor request: IncomingRequest) {
        DispatchQueue.main.async { self.delegate?.quickShare(self, didReceive: request) }
    }

    func inbound(_ connection: InboundConnection, progress: Double) {
        let id = connection.id
        DispatchQueue.main.async { self.delegate?.quickShare(self, incomingTransfer: id, progress: progress) }
    }

    func inbound(_ connection: InboundConnection, finishedWith result: Result<[ReceivedItem], Error>) {
        let id = connection.id
        DispatchQueue.main.async { self.delegate?.quickShare(self, incomingTransfer: id, finishedWith: result) }
    }

    func inboundDidClose(_ connection: InboundConnection) {
        inbound[connection.id] = nil
    }
}
