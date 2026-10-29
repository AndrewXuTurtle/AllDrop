import AppKit
import SwiftUI
import QuickShare

/// The menu-bar icon. Unlike SwiftUI's MenuBarExtra, it accepts files (and links/text) dropped onto it.
@MainActor
final class StatusItem: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuContent(model: model))

        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "AllDrop")
        button.toolTip = "AllDrop — drop files here to send them to a phone"
        button.target = self
        button.action = #selector(togglePopover)

        // Status bar buttons can't be drag destinations themselves; their window forwards
        // dragging messages to its delegate.
        button.window?.registerForDraggedTypes([.fileURL, .URL, .string])
        button.window?.delegate = self
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: Dropping onto the icon

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !model.isSending, Self.content(from: sender.draggingPasteboard) != nil else { return [] }
        item.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        item.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        item.button?.highlight(false)
        guard let content = Self.content(from: sender.draggingPasteboard) else { return false }
        model.prepareToSend(content)
        return true
    }

    /// Files win over links, links over plain text.
    static func content(from pasteboard: NSPasteboard) -> OutgoingContent? {
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath }
        if !fileURLs.isEmpty { return .files(fileURLs) }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           let content = OutgoingContent(sharedText: url.absoluteString), case .url = content {
            return content
        }
        if let string = pasteboard.string(forType: .string) { return OutgoingContent(sharedText: string) }
        return nil
    }
}
