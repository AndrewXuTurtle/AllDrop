import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import QuickShare

struct SendView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            filesHeader
            Divider()
            if let outgoing = model.outgoing {
                OutgoingStatusView(transfer: outgoing, model: model)
            } else if model.toSend == nil {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 40)).foregroundStyle(.tint)
                    Text("Ready to receive as “\(model.deviceName)”").font(.headline)
                    Text("On your phone: Share → Quick Share → pick this Mac.\nTo send, drop files or a link on this window, or click Choose Files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("AllDrop keeps running in the menu bar (the ⬇︎ icon, top right) after you close this window.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    qrSection
                    Divider()
                    nearbySection
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !model.isSending else { return false }
            loadFileURLs(providers) { model.prepareToSend(.files($0)) }
            return true
        }
    }

    private var filesHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: headerSymbol).font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Send Clipboard") { model.sendClipboard() }
                .disabled(model.isSending)
            Button("Choose Files…") { model.chooseFiles() }
                .disabled(model.isSending)
        }
    }

    private var headerSymbol: String {
        switch model.toSend {
        case .url?: return "link"
        case .text?: return "text.quote"
        default: return "doc.on.doc"
        }
    }

    private var title: String {
        switch model.toSend {
        case nil: return "Nothing selected to send"
        case .files(let urls)?: return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        case .url(let url)?: return url.host ?? url.absoluteString
        case .text(let text)?: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var subtitle: String {
        switch model.toSend {
        case nil: return "Drop files onto this window"
        case .files(let urls)?:
            let total = urls.reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        case .url(let url)?: return url.absoluteString
        case .text(let text)?: return "Text · \(text.count) characters"
        }
    }

    private var qrSection: some View {
        VStack(spacing: 10) {
            Text("Samsung & other Android phones").font(.subheadline.weight(.semibold))
            if let url = model.qrCodeURL, let image = QRCode.image(for: url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 190, height: 190)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Scan with the phone's camera. Sending starts as soon as it connects.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Phone must be on the same Wi-Fi.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 240)
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ready to receive nearby").font(.subheadline.weight(.semibold))
            if model.nearby.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking…").foregroundStyle(.secondary)
                }
                Text("Phones only appear here while their Quick Share is open to receive (or after scanning the code).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.nearby) { device in
                    Button {
                        model.send(to: device)
                    } label: {
                        HStack {
                            Image(systemName: device.type.symbolName).frame(width: 20)
                            Text(device.name).lineLimit(1)
                            Spacer()
                            Image(systemName: "paperplane")
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OutgoingStatusView: View {
    let transfer: AppModel.OutgoingTransfer
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: transfer.device.type.symbolName).font(.system(size: 40)).foregroundStyle(.tint)
            Text(transfer.device.name).font(.title3.weight(.semibold))
            status
            HStack {
                if model.isSending {
                    Button("Cancel", role: .cancel) { model.cancelSend() }
                } else {
                    Button("Done") { model.cancelSend() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    @ViewBuilder private var status: some View {
        switch transfer.status {
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Connecting…") }
        case .awaitingAcceptance(let pin):
            VStack(spacing: 4) {
                Text("Waiting for the phone to accept…")
                Text("PIN \(pin)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .sending(let progress):
            ProgressView(value: progress) { Text("Sending… \(Int(progress * 100))%") }
                .frame(width: 280)
        case .done:
            Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
