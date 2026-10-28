// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Crypto
import Foundation

enum OpenSSHPrivateKeyError: LocalizedError {
    case tooLarge
    case invalid
    case unsupportedEncryption
    case unsupportedKeyType

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Файл SSH-ключа превышает допустимые 64 КиБ."
        case .invalid: return "Файл не является корректным приватным ключом OpenSSH Ed25519."
        case .unsupportedEncryption:
            return "Ключ с парольной фразой пока не поддерживается. Выберите другой ключ или вход по SSH-паролю."
        case .unsupportedKeyType: return "Сейчас можно импортировать только приватный ключ OpenSSH Ed25519."
        }
    }
}

/// Reads only the 32-byte Ed25519 seed. The original PEM stays in the user's
/// document provider; callers store the seed in ThisDeviceOnly Keychain.
enum OpenSSHPrivateKey {
    static let maximumFileBytes = 64 * 1024

    static func importSeed(from url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var content = Data()
        while content.count <= maximumFileBytes {
            let next = try file.read(upToCount: maximumFileBytes + 1 - content.count) ?? Data()
            if next.isEmpty { break }
            content.append(next)
        }
        guard content.count <= maximumFileBytes else { throw OpenSSHPrivateKeyError.tooLarge }
        return try parse(content)
    }

    static func parse(_ pem: Data) throws -> Data {
        guard pem.count <= maximumFileBytes else { throw OpenSSHPrivateKeyError.tooLarge }
        guard let text = String(data: pem, encoding: .utf8) else { throw OpenSSHPrivateKeyError.invalid }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 3,
              lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----" else {
            throw OpenSSHPrivateKeyError.invalid
        }
        let encoded = lines.dropFirst().dropLast().joined()
        guard !encoded.isEmpty, encoded.count <= maximumFileBytes,
              let payload = Data(base64Encoded: encoded) else { throw OpenSSHPrivateKeyError.invalid }
        var reader = Reader(payload)
        guard try reader.bytes(15) == Data("openssh-key-v1\0".utf8) else {
            throw OpenSSHPrivateKeyError.invalid
        }
        let cipher = try reader.string(maximum: 64)
        let kdf = try reader.string(maximum: 64)
        let options = try reader.string(maximum: 4_096)
        guard cipher == Data("none".utf8), kdf == Data("none".utf8), options.isEmpty else {
            throw OpenSSHPrivateKeyError.unsupportedEncryption
        }
        guard try reader.u32() == 1 else { throw OpenSSHPrivateKeyError.unsupportedKeyType }
        let publicBlob = try reader.string(maximum: 256)
        var publicReader = Reader(publicBlob)
        guard try publicReader.string(maximum: 64) == Data("ssh-ed25519".utf8) else {
            throw OpenSSHPrivateKeyError.unsupportedKeyType
        }
        let outerPublic = try publicReader.string(maximum: 32)
        guard outerPublic.count == 32, publicReader.remaining == 0 else {
            throw OpenSSHPrivateKeyError.invalid
        }
        let privateBlob = try reader.string(maximum: 512)
        guard reader.remaining == 0, !privateBlob.isEmpty, privateBlob.count % 8 == 0 else {
            throw OpenSSHPrivateKeyError.invalid
        }
        var privateReader = Reader(privateBlob)
        let check = try privateReader.u32()
        guard try privateReader.u32() == check,
              try privateReader.string(maximum: 64) == Data("ssh-ed25519".utf8) else {
            throw OpenSSHPrivateKeyError.invalid
        }
        let innerPublic = try privateReader.string(maximum: 32)
        let privateValue = try privateReader.string(maximum: 64)
        _ = try privateReader.string(maximum: 256) // comment
        guard innerPublic == outerPublic, privateValue.count == 64,
              privateValue.suffix(32) == outerPublic else { throw OpenSSHPrivateKeyError.invalid }
        let seed = Data(privateValue.prefix(32))
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              key.publicKey.rawRepresentation == outerPublic else { throw OpenSSHPrivateKeyError.invalid }
        let padding = privateReader.remaining
        guard (1...8).contains(padding) else { throw OpenSSHPrivateKeyError.invalid }
        for index in 1...padding {
            guard try privateReader.byte() == UInt8(index) else { throw OpenSSHPrivateKeyError.invalid }
        }
        guard privateReader.remaining == 0 else { throw OpenSSHPrivateKeyError.invalid }
        return seed
    }

    private struct Reader {
        let data: Data
        private var offset = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - offset }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw OpenSSHPrivateKeyError.invalid }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func byte() throws -> UInt8 {
            guard remaining > 0 else { throw OpenSSHPrivateKeyError.invalid }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func u32() throws -> UInt32 {
            try bytes(4).reduce(0) { ($0 << 8) | UInt32($1) }
        }
        mutating func string(maximum: Int) throws -> Data {
            let length = try u32()
            guard length <= maximum else { throw OpenSSHPrivateKeyError.invalid }
            return try bytes(Int(length))
        }
    }
}
