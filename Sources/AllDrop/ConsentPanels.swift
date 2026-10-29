import AppKit
import SwiftUI
import QuickShare

/// Floating "Accept / Decline" prompts for incoming transfers, one per request.
@MainActor
final class ConsentPanels {
    private var panels: [String: NSPanel] = [:]

    func show(_ request: IncomingRequest, respond: @escaping (Bool) -> Void) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ConsentView(request: request, respond: respond))
        panel.setContentSize(panel.contentView!.fittingSize)

        if let screen = NSScreen.main?.visibleFrame {
            let offset = CGFloat(panels.count) * 24
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 16 - offset,
                                               y: screen.maxY - 16 - offset))
        }
        panels[request.id] = panel
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
    }

    func close(_ id: String) {
        panels.removeValue(forKey: id)?.close()
    }
}

private struct ConsentView: View {
    let request: IncomingRequest
    let respond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: request.senderType.symbolName)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.senderName).font(.headline)
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack {
                Label("PIN \(request.pin)", systemImage: "lock.shield")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Check that the phone shows the same PIN")
                Spacer()
                Button("Decline") { respond(false) }
                Button("Accept") { respond(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var summary: String {
        switch request.content {
        case .files(let files) where files.count == 1:
            return "\(files[0].name) · \(ByteCountFormatter.string(fromByteCount: files[0].size, countStyle: .file))"
        case .files(let files):
            let total = files.reduce(0) { $0 + $1.size }
            return "\(files.count) files · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        case .text:
            return "Text (will be copied to your clipboard)"
        case .url(let title):
            return "Link: \(title)"
        }
    }
}
