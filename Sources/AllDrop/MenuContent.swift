import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickShare

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            dropZone
            Button {
                model.sendClipboard()
            } label: {
                Label("Send Clipboard", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            if !model.incoming.isEmpty { incomingList }
            Divider()
            HStack {
                Button("Open Window") { MainWindow.shared.show() }
                Button("Downloads") { NSWorkspace.shared.open(model.service.downloadsDirectory) }
                SettingsLink { Text("Settings") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isReceiving ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("AllDrop").font(.headline)
                if let error = model.receiveError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Visible in Quick Share as “\(model.deviceName)”")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dropZone: some View {
        Button {
            model.chooseFiles()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.doc.on.clipboard").font(.title2)
                Text("Drop files here or click to send").font(.callout)
                Text("Tip: you can also drop onto the menu-bar icon").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { model.prepareToSend(.files($0)) }
            return true
        }
    }

    private var incomingList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Received").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Clear") { model.clearFinished() }.buttonStyle(.borderless).font(.caption)
            }
            ForEach(model.incoming.prefix(5)) { transfer in
                IncomingRow(transfer: transfer, model: model)
            }
        }
    }
}

private struct IncomingRow: View {
    let transfer: AppModel.IncomingTransfer
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.request.senderType.symbolName).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.request.senderName).font(.callout).lineLimit(1)
                status
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder private var status: some View {
        switch transfer.status {
        case .awaitingConsent:
            Text("Waiting for you to accept").font(.caption).foregroundStyle(.secondary)
        case .receiving(let progress):
            ProgressView(value: progress).progressViewStyle(.linear)
        case .done(let items):
            Text(describe(items)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch transfer.status {
        case .awaitingConsent:
            Button("Accept") { model.respond(to: transfer.id, accept: true) }.controlSize(.small)
        case .done(let items):
            let files = items.compactMap { if case .file(let url) = $0 { url } else { nil } }
            if !files.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(files)
                } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        default:
            EmptyView()
        }
    }

    private func describe(_ items: [ReceivedItem]) -> String {
        if items.count == 1 {
            switch items[0] {
            case .file(let url): return url.lastPathComponent
            case .text: return "Text copied to clipboard"
            case .url(let url): return url.host ?? url.absoluteString
            }
        }
        return "\(items.count) files"
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Show AllDrop in the Dock", isOn: $model.showInDock)
            Text("Drop files on the Dock icon to send them.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Text("Keeps your Mac visible to phones whenever you're logged in.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.settingsError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}

/// Resolves dropped file URLs and hands them back on the main actor.
@MainActor
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [URL] = []
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL, !url.hasDirectoryPath {
                lock.lock(); urls.append(url); lock.unlock()
            }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { if !urls.isEmpty { completion(urls) } }
    }
}
