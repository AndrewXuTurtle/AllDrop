import AppKit
import SwiftUI
import QuickShare

@main
struct AllDropApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // The menu-bar icon and main window are AppKit-managed (see StatusItem and MainWindow);
        // this scene only provides the standard Settings window (⌘,).
        Settings {
            SettingsView(model: AppModel.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItem?
    private var pendingOpenURLs: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            model.start()
            statusItem = StatusItem(model: model)
            NSApp.servicesProvider = ServicesProvider()
            launched = true
            if pendingOpenURLs.isEmpty {
                // The menu-bar icon is easy to miss (or hidden behind the notch), so greet with a window.
                MainWindow.shared.show()
            } else {
                model.prepareToSend(.files(pendingOpenURLs))
                pendingOpenURLs = []
            }
        }
    }

    /// Files dropped on the Dock/Finder icon, or opened with "Open With → AllDrop".
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        MainActor.assumeIsolated {
            if launched { AppModel.shared.prepareToSend(.files(files)) } else { pendingOpenURLs += files }
        }
    }

    /// Opening the app again while it's running (Finder, Spotlight, Dock) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindow.shared.show() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The send/status window, managed by AppKit so it can be opened from anywhere, not just from a view.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show() {
        let model = AppModel.shared
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "AllDrop"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SendView(model: model))
            window.delegate = self
            window.center()
            self.window = window
        }
        model.beginSendSession()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.endSendSession()
    }
}

/// Finder → right-click → Services (or Quick Actions) → "Send with AllDrop", and the same for selected text.
/// Declared under NSServices in Info.plist.
final class ServicesProvider: NSObject {
    @objc func sendFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        MainActor.assumeIsolated { AppModel.shared.prepareToSend(.files(urls)) }
    }

    @objc func sendText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), let content = OutgoingContent(sharedText: text) else { return }
        MainActor.assumeIsolated { AppModel.shared.prepareToSend(content) }
    }
}
