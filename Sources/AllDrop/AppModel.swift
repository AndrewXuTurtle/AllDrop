import AppKit
import ServiceManagement
import SwiftUI
import QuickShare

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct IncomingTransfer: Identifiable {
        enum Status {
            case awaitingConsent
            case receiving(Double)
            case done([ReceivedItem])
            case failed(String)
        }
        let request: IncomingRequest
        var status: Status
        var id: String { request.id }
    }

    struct OutgoingTransfer {
        enum Status {
            case connecting
            case awaitingAcceptance(pin: String)
            case sending(Double)
            case done
            case failed(String)
        }
        let id: String
        let device: RemoteDevice
        var status: Status
    }

    let service = QuickShareService()
    @Published private(set) var isReceiving = false
    @Published private(set) var receiveError: String?
    @Published private(set) var incoming: [IncomingTransfer] = []
    @Published private(set) var nearby: [RemoteDevice] = []
    @Published var toSend: OutgoingContent?
    @Published private(set) var outgoing: OutgoingTransfer?
    @Published private(set) var qrCodeURL: URL?

    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyDockPolicy()
        }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var settingsError: String?

    private let consentPanels = ConsentPanels()

    var deviceName: String { service.deviceName }

    private init() {
        showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        service.delegate = self
    }

    func start() {
        applyDockPolicy()
        do {
            try service.startReceiving()
            isReceiving = true
        } catch {
            receiveError = error.localizedDescription
        }
    }

    // MARK: Settings

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settingsError = nil
        } catch {
            settingsError = "Couldn't change login item: \(error.localizedDescription). Move AllDrop to Applications first."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Receiving

    func respond(to id: String, accept: Bool) {
        service.respond(to: id, accept: accept)
        consentPanels.close(id)
        guard let index = incoming.firstIndex(where: { $0.id == id }) else { return }
        if accept {
            incoming[index].status = .receiving(0)
        } else {
            incoming.remove(at: index)
        }
    }

    func clearFinished() {
        incoming.removeAll {
            switch $0.status {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    // MARK: Sending

    /// Entry point for every way of sending: drops, the file picker, Finder services, Open With, clipboard.
    func prepareToSend(_ content: OutgoingContent) {
        guard !isSending else { return }
        if case .files(let urls) = content, urls.isEmpty { return }
        outgoing = nil
        toSend = content
        MainWindow.shared.show()
    }

    func sendClipboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            prepareToSend(.files(urls))
        } else if let string = pasteboard.string(forType: .string), let content = OutgoingContent(sharedText: string) {
            prepareToSend(content)
        } else {
            NSSound.beep()
        }
    }

    func beginSendSession() {
        guard qrCodeURL == nil else { return }
        qrCodeURL = service.startQRCodeSession()
    }

    func endSendSession() {
        service.endQRCodeSession()
        service.stopDiscovery()
        qrCodeURL = nil
        nearby = []
        if !isSending { outgoing = nil }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { prepareToSend(.files(panel.urls)) }
    }

    func send(to device: RemoteDevice) {
        guard let toSend, !isSending else { return }
        let id = service.send(toSend, to: device) { [weak self] event in
            self?.handle(event)
        }
        outgoing = OutgoingTransfer(id: id, device: device, status: .connecting)
    }

    func cancelSend() {
        if let outgoing, isSending { service.cancelSend(outgoing.id) }
        outgoing = nil
    }

    var isSending: Bool {
        switch outgoing?.status {
        case .connecting?, .awaitingAcceptance?, .sending?: return true
        default: return false
        }
    }

    private func handle(_ event: OutgoingEvent) {
        guard outgoing != nil else { return }
        switch event {
        case .connecting:
            outgoing?.status = .connecting
        case .awaitingAcceptance(let pin):
            outgoing?.status = .awaitingAcceptance(pin: pin)
        case .sending(let progress):
            outgoing?.status = .sending(progress)
        case .completed:
            outgoing?.status = .done
            toSend = nil
        case .failed(let error):
            outgoing?.status = .failed(error.localizedDescription)
        }
    }
}

extension AppModel: QuickShareServiceDelegate {
    nonisolated func quickShare(_ service: QuickShareService, didReceive request: IncomingRequest) {
        MainActor.assumeIsolated {
            incoming.insert(IncomingTransfer(request: request, status: .awaitingConsent), at: 0)
            consentPanels.show(request) { [weak self] accept in self?.respond(to: request.id, accept: accept) }
        }
    }

    nonisolated func quickShare(_ service: QuickShareService, incomingTransfer id: String, progress: Double) {
        MainActor.assumeIsolated {
            guard let index = incoming.firstIndex(where: { $0.id == id }) else { return }
            incoming[index].status = .receiving(progress)
        }
    }

    nonisolated func quickShare(_ service: QuickShareService, incomingTransfer id: String,
                                finishedWith result: Result<[ReceivedItem], Error>) {
        MainActor.assumeIsolated {
            consentPanels.close(id)
            guard let index = incoming.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let items):
                incoming[index].status = .done(items)
                Self.deliver(items)
            case .failure(let error):
                incoming[index].status = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated func quickShare(_ service: QuickShareService, didUpdateNearbyDevices devices: [RemoteDevice]) {
        MainActor.assumeIsolated { nearby = devices }
    }

    nonisolated func quickShare(_ service: QuickShareService, qrCodeScannedBy device: RemoteDevice) {
        MainActor.assumeIsolated { send(to: device) }
    }

    /// Links open in the browser and text goes to the clipboard, like they do on a phone.
    private static func deliver(_ items: [ReceivedItem]) {
        for item in items {
            switch item {
            case .url(let url):
                NSWorkspace.shared.open(url)
            case .text(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .file:
                break
            }
        }
    }
}
