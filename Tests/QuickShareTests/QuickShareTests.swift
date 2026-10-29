import XCTest
import Network
import CryptoKit
@testable import QuickShare

final class CryptoTests: XCTestCase {
    func testD2DSaltMatchesProtocolConstant() {
        let salt = Data(SHA256.hash(data: Data("D2D".utf8)))
        XCTAssertEqual(salt.map { String(format: "%02X", $0) }.joined(),
                       "82AA55A0D397F88346CA1CEE8D3909B95F13FA7DEB1D4AB38376B8256DA85510")
    }

    func testBigIntegerCoordinateRoundTrip() {
        let high = Data([0x80] + Array(repeating: 1, count: 31))
        XCTAssertEqual(high.signedBigEndian.count, 33)
        XCTAssertEqual(high.signedBigEndian.unsignedFixedWidth(32), high)
        XCTAssertEqual(Data([1, 2]).unsignedFixedWidth(4), Data([0, 0, 1, 2]))
    }

    func testPublicKeyRoundTrip() throws {
        let key = P256.KeyAgreement.PrivateKey().publicKey
        XCTAssertEqual(try UKEY2.decode(try UKEY2.encode(key)).rawRepresentation, key.rawRepresentation)
    }

    func testEndpointInfoRoundTrip() throws {
        var info = EndpointInfo(name: "Andrew's MacBook", deviceType: .laptop)
        var raw = info.serialized()
        raw.append(contentsOf: [1, 3, 9, 8, 7]) // QR TLV
        let parsed = try XCTUnwrap(EndpointInfo(raw))
        XCTAssertEqual(parsed.name, "Andrew's MacBook")
        XCTAssertEqual(parsed.deviceType, .laptop)
        XCTAssertEqual(parsed.qrCodeData, Data([9, 8, 7]))
        info.name = nil
    }

    func testUniqueDestinationStripsPaths() {
        let dir = FileManager.default.temporaryDirectory
        var reserved = Set<String>()
        let a = InboundConnection.uniqueDestination(in: dir, for: "../../etc/passwd", avoiding: &reserved)
        XCTAssertEqual(a.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        let b = InboundConnection.uniqueDestination(in: dir, for: "passwd", avoiding: &reserved)
        XCTAssertEqual(b.lastPathComponent, "passwd (1)")
    }
}

final class QRCodeTests: XCTestCase {
    func testURLCarriesEvenYCompressedKey() throws {
        let session = QuickShareService.QRSession()
        let key = try XCTUnwrap(session.url.absoluteString.components(separatedBy: "#key=").last)
        let data = try XCTUnwrap(Data(urlSafeBase64: key))
        XCTAssertEqual(data.count, 35)
        XCTAssertEqual(Array(data.prefix(3)), [0, 0, 2])
    }

    func testVisibleReceiverEchoesToken() {
        let session = QuickShareService.QRSession()
        XCTAssertEqual(session.match(session.advertisingToken), .visible)
        XCTAssertEqual(session.match(.random(16)), .none)
    }

    func testHiddenReceiverNameDecrypts() throws {
        let session = QuickShareService.QRSession()
        let sealed = try AES.GCM.seal(Data("Galaxy S25".utf8), using: session.nameKey,
                                      authenticating: session.advertisingToken)
        XCTAssertEqual(session.match(try XCTUnwrap(sealed.combined)), .hidden(name: "Galaxy S25"))
        // A different QR session must not be able to read it.
        XCTAssertEqual(QuickShareService.QRSession().match(try XCTUnwrap(sealed.combined)), .none)
    }
}

final class SharedTextTests: XCTestCase {
    func testLinksBecomeURLs() {
        XCTAssertEqual(OutgoingContent(sharedText: "  https://example.com/x?y=1\n"), .url(URL(string: "https://example.com/x?y=1")!))
    }

    func testOtherTextStaysText() {
        XCTAssertEqual(OutgoingContent(sharedText: "see https://example.com"), .text("see https://example.com"))
        XCTAssertEqual(OutgoingContent(sharedText: "ftp://example.com"), .text("ftp://example.com"))
        XCTAssertEqual(OutgoingContent(sharedText: "hello"), .text("hello"))
        XCTAssertNil(OutgoingContent(sharedText: " \n "))
    }
}

/// Runs a real transfer between two services over loopback: handshake, encryption, payloads.
final class LoopbackTests: XCTestCase, QuickShareServiceDelegate {
    var receiver: QuickShareService!
    var sender: QuickShareService!
    var inbox: URL!
    var requestReceived: XCTestExpectation?
    var finished: XCTestExpectation?
    var pinSeenByReceiver: String?
    var result: Result<[ReceivedItem], Error>?

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        receiver = QuickShareService(deviceName: "Receiver", downloadsDirectory: inbox)
        receiver.delegate = self
        sender = QuickShareService(deviceName: "Sender")
        try receiver.startReceiving()
    }

    override func tearDown() {
        receiver.stopReceiving()
        try? FileManager.default.removeItem(at: inbox)
    }

    func port() throws -> NWEndpoint {
        for _ in 0..<50 {
            if let port = receiver.queue.sync(execute: { receiver.listeningPort }), port != 0 {
                return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("listener never became ready")
    }

    func testSendsFilesEndToEnd() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("qs-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let big = Data.random(1_300_000) // spans several chunks
        let bigURL = source.appendingPathComponent("photo.jpg")
        let emptyURL = source.appendingPathComponent("empty.txt")
        try big.write(to: bigURL)
        try Data().write(to: emptyURL)

        requestReceived = expectation(description: "request")
        finished = expectation(description: "finished")
        let senderDone = expectation(description: "sender completed")
        var senderPin: String?
        sender.send(.files([bigURL, emptyURL]), to: try port(), transferID: "t1") { event in
            switch event {
            case .awaitingAcceptance(let pin): senderPin = pin
            case .completed: senderDone.fulfill()
            case .failed(let error): XCTFail("sender failed: \(error)"); senderDone.fulfill()
            default: break
            }
        }
        wait(for: [requestReceived!, finished!, senderDone], timeout: 15)

        XCTAssertNotNil(senderPin)
        XCTAssertEqual(senderPin, pinSeenByReceiver, "both sides must derive the same PIN")
        let items = try XCTUnwrap(try result?.get())
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("photo.jpg")), big)
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("empty.txt")), Data())
    }

    func testSendsURL() throws {
        requestReceived = expectation(description: "request")
        finished = expectation(description: "finished")
        sender.send(.url(URL(string: "https://example.com/a?b=c")!), to: try port(), transferID: "t2") { _ in }
        wait(for: [requestReceived!, finished!], timeout: 15)
        guard case .url(let url)? = try result?.get().first else { return XCTFail("no url") }
        XCTAssertEqual(url.absoluteString, "https://example.com/a?b=c")
    }

    func testSendsText() throws {
        requestReceived = expectation(description: "request")
        finished = expectation(description: "finished")
        sender.send(.text("Halo dari Mac 👋"), to: try port(), transferID: "t4") { _ in }
        wait(for: [requestReceived!, finished!], timeout: 15)
        guard case .text(let text)? = try result?.get().first else { return XCTFail("no text") }
        XCTAssertEqual(text, "Halo dari Mac 👋")
    }

    func testSenderCancelCleansUpPartialFile() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("qs-big-\(UUID().uuidString)")
        try Data.random(40_000_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        requestReceived = expectation(description: "request")
        finished = expectation(description: "receiver sees failure")
        let cancelled = expectation(description: "sender cancelled")
        var didCancel = false
        sender.send(.files([source]), to: try port(), transferID: "t5") { [sender] event in
            if case .sending(let progress) = event, progress > 0.05, !didCancel {
                didCancel = true
                sender!.cancelSend("t5")
            }
            if case .failed = event { cancelled.fulfill() }
        }
        wait(for: [requestReceived!, cancelled, finished!], timeout: 30)
        XCTAssertThrowsError(try result?.get())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
        XCTAssertEqual(leftovers, [], "partial download must be deleted")
    }

    func testDeclineReachesSender() throws {
        decline = true
        requestReceived = expectation(description: "request")
        let failed = expectation(description: "sender sees rejection")
        sender.send(.text("hello"), to: try port(), transferID: "t3") { event in
            if case .failed(let error) = event {
                if case QuickShareError.rejected = error {} else { XCTFail("unexpected \(error)") }
                failed.fulfill()
            }
        }
        wait(for: [requestReceived!, failed], timeout: 15)
    }

    var decline = false

    func quickShare(_ service: QuickShareService, didReceive request: IncomingRequest) {
        XCTAssertEqual(request.senderName, "Sender")
        pinSeenByReceiver = request.pin
        requestReceived?.fulfill()
        service.respond(to: request.id, accept: !decline)
    }
    func quickShare(_ service: QuickShareService, incomingTransfer id: String, progress: Double) {}
    func quickShare(_ service: QuickShareService, incomingTransfer id: String, finishedWith result: Result<[ReceivedItem], Error>) {
        self.result = result
        finished?.fulfill()
    }
    func quickShare(_ service: QuickShareService, didUpdateNearbyDevices devices: [RemoteDevice]) {}
    func quickShare(_ service: QuickShareService, qrCodeScannedBy device: RemoteDevice) {}
}
