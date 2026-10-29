import Foundation

public enum DeviceType: Int, Sendable {
    case unknown = 0, phone, tablet, laptop, car, foldable, xr

    public var symbolName: String {
        switch self {
        case .phone, .foldable: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        case .car: return "car"
        case .xr: return "visionpro"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// The "endpoint info" blob carried in the mDNS TXT record (`n`) and in connection requests.
///
/// Layout: 1 byte flags (version:3 | hidden:1 | deviceType:3 | reserved:1), 16 opaque bytes,
/// then (if not hidden) a length-prefixed UTF-8 name, then optional TLV records.
struct EndpointInfo {
    var name: String?
    var deviceType: DeviceType
    var qrCodeData: Data?
    var opaque: Data = .random(16)

    init(name: String, deviceType: DeviceType) {
        self.name = name
        self.deviceType = deviceType
    }

    init?(_ raw: Data) {
        let data = [UInt8](raw)
        guard data.count >= 17 else { return nil }
        let hidden = data[0] & 0x10 != 0
        deviceType = DeviceType(rawValue: Int(data[0] >> 1) & 0x07) ?? .unknown
        opaque = Data(data[1..<17])
        var offset = 17
        if !hidden {
            guard data.count > offset else { return nil }
            let length = Int(data[offset])
            offset += 1
            guard data.count >= offset + length else { return nil }
            name = String(decoding: data[offset..<(offset + length)], as: UTF8.self)
            offset += length
        }
        while data.count - offset >= 2 {
            let type = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard data.count - offset >= length else { break }
            if type == 1 { qrCodeData = Data(data[offset..<(offset + length)]) }
            offset += length
        }
    }

    func serialized() -> Data {
        var out = Data([UInt8(deviceType.rawValue << 1)])
        out.append(opaque)
        var nameBytes = Data((name ?? "").utf8)
        if nameBytes.count > 255 { nameBytes = nameBytes.prefix(255) }
        out.append(UInt8(nameBytes.count))
        out.append(nameBytes)
        return out
    }
}
