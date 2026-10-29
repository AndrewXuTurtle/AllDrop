import Foundation
import Security

extension Data {
    /// Decodes URL-safe base64, with or without padding.
    init?(urlSafeBase64 string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    /// URL-safe base64 without padding, which is what Quick Share puts in service names, TXT records and QR codes.
    var urlSafeBase64: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        guard count > 0 else { return data }
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }

    /// Encodes an unsigned big-endian magnitude the way Java's BigInteger.toByteArray() does,
    /// which is what Android expects for EC coordinates.
    var signedBigEndian: Data {
        if let first, first & 0x80 != 0 { return Data([0]) + self }
        return self
    }

    /// Normalises a BigInteger-style encoding (possibly with a leading sign byte, possibly short) to exactly `length` bytes.
    func unsignedFixedWidth(_ length: Int) -> Data? {
        var bytes = [UInt8](self)
        while bytes.count > length, bytes.first == 0 { bytes.removeFirst() }
        guard bytes.count <= length else { return nil }
        return Data(repeating: 0, count: length - bytes.count) + bytes
    }
}

extension Int64 {
    static func randomPayloadID() -> Int64 { Int64.random(in: Int64.min...Int64.max) }
}

public enum QuickShareError: LocalizedError, Sendable {
    case protocolViolation(String)
    case ukey2(String)
    case crypto(String)
    case io(String)
    case rejected
    case notEnoughSpace
    case unsupportedType
    case timedOut
    case cancelled
    case connectionLost

    public var errorDescription: String? {
        switch self {
        case .protocolViolation(let m): return "Protocol error: \(m)"
        case .ukey2(let m): return "Key exchange failed: \(m)"
        case .crypto(let m): return "Encryption error: \(m)"
        case .io(let m): return "File error: \(m)"
        case .rejected: return "The other device declined the transfer."
        case .notEnoughSpace: return "The other device doesn't have enough space."
        case .unsupportedType: return "The other device doesn't support this kind of content."
        case .timedOut: return "The other device didn't respond in time."
        case .cancelled: return "The transfer was cancelled."
        case .connectionLost: return "The connection was lost."
        }
    }
}
