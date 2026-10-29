import Foundation
import CryptoKit
import CommonCrypto

/// UKEY2 handshake helpers (P-256 + SHA-512 commitment), see https://github.com/google/ukey2
enum UKEY2 {
    static let nextProtocol = "AES_256_CBC-HMAC_SHA256"

    static func encode(_ key: P256.KeyAgreement.PublicKey) throws -> Data {
        let raw = key.rawRepresentation // X || Y, 32 bytes each
        var generic = Securemessage_GenericPublicKey()
        generic.type = .ecP256
        generic.ecP256PublicKey.x = Data(raw.prefix(32)).signedBigEndian
        generic.ecP256PublicKey.y = Data(raw.suffix(32)).signedBigEndian
        return try generic.serializedData()
    }

    static func decode(_ data: Data) throws -> P256.KeyAgreement.PublicKey {
        let generic = try Securemessage_GenericPublicKey(serializedBytes: data)
        guard generic.hasEcP256PublicKey,
              let x = generic.ecP256PublicKey.x.unsignedFixedWidth(32),
              let y = generic.ecP256PublicKey.y.unsignedFixedWidth(32)
        else { throw QuickShareError.ukey2("peer did not send a P-256 key") }
        do {
            return try P256.KeyAgreement.PublicKey(rawRepresentation: x + y)
        } catch {
            throw QuickShareError.ukey2("peer key is not on the curve")
        }
    }

    static func message(_ type: Securegcm_Ukey2Message.TypeEnum, _ body: Data) throws -> Data {
        var msg = Securegcm_Ukey2Message()
        msg.messageType = type
        msg.messageData = body
        return try msg.serializedData()
    }
}

/// Keys derived from a completed UKEY2 handshake, oriented for one side of the connection.
struct SessionKeys {
    let authString: Data
    let pin: String
    let encryptKey: SymmetricKey
    let decryptKey: SymmetricKey
    let sendHMACKey: SymmetricKey
    let receiveHMACKey: SymmetricKey

    /// `clientInit` and `serverInit` are the full serialized Ukey2Message frames, without length prefix.
    init(privateKey: P256.KeyAgreement.PrivateKey, peerKey: P256.KeyAgreement.PublicKey,
         clientInit: Data, serverInit: Data, isServer: Bool) throws {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let dhs = shared.withUnsafeBytes { SymmetricKey(data: SHA256.hash(data: Data($0))) }
        let info = clientInit + serverInit
        let auth = Self.hkdf(dhs, salt: Data("UKEY2 v1 auth".utf8), info: info)
        let next = Self.hkdf(dhs, salt: Data("UKEY2 v1 next".utf8), info: info)

        authString = auth.withUnsafeBytes { Data($0) }
        pin = Self.pin(from: authString)

        let d2dSalt = Data(SHA256.hash(data: Data("D2D".utf8)))
        let d2dClient = Self.hkdf(next, salt: d2dSalt, info: Data("client".utf8))
        let d2dServer = Self.hkdf(next, salt: d2dSalt, info: Data("server".utf8))

        let smSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))
        let clientEnc = Self.hkdf(d2dClient, salt: smSalt, info: Data("ENC:2".utf8))
        let clientSig = Self.hkdf(d2dClient, salt: smSalt, info: Data("SIG:1".utf8))
        let serverEnc = Self.hkdf(d2dServer, salt: smSalt, info: Data("ENC:2".utf8))
        let serverSig = Self.hkdf(d2dServer, salt: smSalt, info: Data("SIG:1".utf8))

        if isServer {
            (encryptKey, sendHMACKey, decryptKey, receiveHMACKey) = (serverEnc, serverSig, clientEnc, clientSig)
        } else {
            (encryptKey, sendHMACKey, decryptKey, receiveHMACKey) = (clientEnc, clientSig, serverEnc, serverSig)
        }
    }

    static func hkdf(_ ikm: SymmetricKey, salt: Data, info: Data, length: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: length)
    }

    /// The 4-digit code both screens show, derived from the UKEY2 auth string the same way Chromium does.
    static func pin(from authString: Data) -> String {
        var hash = 0
        var multiplier = 1
        for byte in authString {
            hash = (hash + Int(Int8(bitPattern: byte)) * multiplier) % 9973
            multiplier = (multiplier * 31) % 9973
        }
        return String(format: "%04d", abs(hash))
    }
}

/// SecureMessage framing (AES-256-CBC + HMAC-SHA256) with per-direction sequence numbers.
struct SecureChannel {
    let keys: SessionKeys
    private var sendSequence: Int32 = 0
    private var receiveSequence: Int32 = 0

    init(keys: SessionKeys) { self.keys = keys }

    mutating func seal(_ frame: Location_Nearby_Connections_OfflineFrame) throws -> Data {
        sendSequence += 1
        var d2d = Securegcm_DeviceToDeviceMessage()
        d2d.sequenceNumber = sendSequence
        d2d.message = try frame.serializedData()

        let iv = Data.random(16)
        var headerAndBody = Securemessage_HeaderAndBody()
        headerAndBody.body = try AESCBC.run(CCOperation(kCCEncrypt), try d2d.serializedData(), key: keys.encryptKey, iv: iv)
        headerAndBody.header.encryptionScheme = .aes256Cbc
        headerAndBody.header.signatureScheme = .hmacSha256
        headerAndBody.header.iv = iv
        var metadata = Securegcm_GcmMetadata()
        metadata.type = .deviceToDeviceMessage
        metadata.version = 1
        headerAndBody.header.publicMetadata = try metadata.serializedData()

        var message = Securemessage_SecureMessage()
        message.headerAndBody = try headerAndBody.serializedData()
        message.signature = Data(HMAC<SHA256>.authenticationCode(for: message.headerAndBody, using: keys.sendHMACKey))
        return try message.serializedData()
    }

    mutating func open(_ data: Data) throws -> Location_Nearby_Connections_OfflineFrame {
        let message = try Securemessage_SecureMessage(serializedBytes: data)
        guard message.hasHeaderAndBody, message.hasSignature else {
            throw QuickShareError.protocolViolation("secure message without body or signature")
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(message.signature, authenticating: message.headerAndBody,
                                                     using: keys.receiveHMACKey) else {
            throw QuickShareError.crypto("bad message signature")
        }
        let headerAndBody = try Securemessage_HeaderAndBody(serializedBytes: message.headerAndBody)
        let plain = try AESCBC.run(CCOperation(kCCDecrypt), headerAndBody.body, key: keys.decryptKey, iv: headerAndBody.header.iv)
        let d2d = try Securegcm_DeviceToDeviceMessage(serializedBytes: plain)
        receiveSequence += 1
        guard d2d.sequenceNumber == receiveSequence else {
            throw QuickShareError.protocolViolation("sequence number \(d2d.sequenceNumber), expected \(receiveSequence)")
        }
        return try Location_Nearby_Connections_OfflineFrame(serializedBytes: d2d.message)
    }
}

enum AESCBC {
    static func run(_ operation: CCOperation, _ input: Data, key: SymmetricKey, iv: Data) throws -> Data {
        guard iv.count == kCCBlockSizeAES128 else { throw QuickShareError.crypto("bad IV length") }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { inBytes in
                    output.withUnsafeMutableBytes { outBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, keyBytes.count, ivBytes.baseAddress,
                                inBytes.baseAddress, inBytes.count,
                                outBytes.baseAddress, outBytes.count, &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw QuickShareError.crypto("CCCrypt status \(status)") }
        return output.prefix(outputLength)
    }
}
