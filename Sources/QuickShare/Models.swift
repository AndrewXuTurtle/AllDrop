import Foundation

/// A Quick Share receiver found on the local network.
public struct RemoteDevice: Identifiable, Hashable, Sendable {
    /// The 4-character Nearby endpoint ID.
    public let id: String
    public let name: String
    public let type: DeviceType
}

public struct IncomingFile: Hashable, Sendable {
    public let name: String
    public let size: Int64
    public let mimeType: String
}

public enum IncomingContent: Sendable {
    case files([IncomingFile])
    case text(size: Int64)
    case url(title: String)
}

/// Someone wants to send us something; answer with `QuickShareService.respond(to:accept:)`.
public struct IncomingRequest: Identifiable, Sendable {
    public let id: String
    public let senderName: String
    public let senderType: DeviceType
    /// Shown on the sender's screen too, so the user can confirm who they're talking to.
    public let pin: String
    public let content: IncomingContent
}

public enum ReceivedItem: Sendable {
    case file(URL)
    case text(String)
    case url(URL)
}

public enum OutgoingContent: Sendable, Equatable {
    case files([URL])
    case text(String)
    case url(URL)

    /// Interprets shared or pasted text: a lone web link is sent as a link (opens on the phone),
    /// anything else as text. Returns nil for blank input.
    public init?(sharedText: String) {
        let trimmed = sharedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            self = .url(url)
        } else {
            self = .text(sharedText)
        }
    }
}

public enum OutgoingEvent: Sendable {
    case connecting
    /// Connected and waiting for the other person to tap Accept.
    case awaitingAcceptance(pin: String)
    case sending(progress: Double)
    case completed
    case failed(Error)
}
