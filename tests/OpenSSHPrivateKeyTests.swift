// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Crypto
import Foundation

@main
struct OpenSSHPrivateKeyTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sovagrid-key-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }

        let plain = folder.appendingPathComponent("plain")
        try generateKey(at: plain, passphrase: "")
        let seed = try OpenSSHPrivateKey.importSeed(from: plain)
        precondition(seed.count == 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicText = try String(contentsOf: plain.appendingPathExtension("pub"), encoding: .utf8)
        let encoded = publicText.split(separator: " ")[1]
        let blob = Data(base64Encoded: String(encoded))!
        precondition(blob.suffix(32) == key.publicKey.rawRepresentation)

        let encrypted = folder.appendingPathComponent("encrypted")
        try generateKey(at: encrypted, passphrase: "test-passphrase")
        do {
            _ = try OpenSSHPrivateKey.importSeed(from: encrypted)
            preconditionFailure("Encrypted key should require its passphrase")
        } catch OpenSSHPrivateKeyError.missingPassphrase {}
        let encryptedSeed = try OpenSSHPrivateKey.importSeed(from: encrypted, passphrase: "test-passphrase")
        precondition(encryptedSeed.count == 32)
        let encryptedPublic = try String(contentsOf: encrypted.appendingPathExtension("pub"), encoding: .utf8)
        let encryptedBlob = Data(base64Encoded: String(encryptedPublic.split(separator: " ")[1]))!
        let encryptedKey = try Curve25519.Signing.PrivateKey(rawRepresentation: encryptedSeed)
        precondition(encryptedBlob.suffix(32) == encryptedKey.publicKey.rawRepresentation)
        do {
            _ = try OpenSSHPrivateKey.importSeed(from: encrypted, passphrase: "wrong-passphrase")
            preconditionFailure("Wrong passphrase should be rejected")
        } catch OpenSSHPrivateKeyError.wrongPassphrase {}
        let encryptedPEM = try Data(contentsOf: encrypted)
        let encodedLines = String(data: encryptedPEM, encoding: .utf8)!.split(whereSeparator: \.isNewline)
        var encryptedWire = Data(base64Encoded: encodedLines.dropFirst().dropLast().joined())!
        encryptedWire[encryptedWire.count - 1] ^= 1
        let damagedPEM = Data(("-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + encryptedWire.base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----\n").utf8)
        do {
            _ = try OpenSSHPrivateKey.parse(damagedPEM, passphrase: "test-passphrase")
            preconditionFailure("Damaged encrypted key should be rejected")
        } catch is OpenSSHPrivateKeyError {}

        var broken = try Data(contentsOf: plain)
        broken[broken.count / 2] = 0
        do {
            _ = try OpenSSHPrivateKey.parse(broken)
            preconditionFailure("Malformed key should be rejected")
        } catch OpenSSHPrivateKeyError.invalid {}

        do {
            _ = try OpenSSHPrivateKey.parse(Data(repeating: 65, count: 64 * 1024 + 1))
            preconditionFailure("Oversized key should be rejected")
        } catch OpenSSHPrivateKeyError.tooLarge {}
        try verifyWireValidation(seed)
        if CommandLine.arguments.count == 2 {
            _ = try OpenSSHPrivateKey.importSeed(from: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("Existing OpenSSH Ed25519 key accepted without displaying key material.")
        }
        print("OpenSSH Ed25519 import: plain and encrypted keys, public key match, missing/wrong passphrase, tampering, size and 11 wire cases passed.")
    }

    static func verifyWireValidation(_ seed: Data) throws {
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let otherKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 37, count: 32))
            .publicKey.rawRepresentation
        func wire(outer: Data = publicKey, inner: Data = publicKey,
                  privateSeed: Data = seed, suffix: Data = publicKey,
                  firstCheck: UInt32 = 42, secondCheck: UInt32 = 42,
                  keyType: String = "ssh-ed25519", count: UInt32 = 1,
                  paddingCorrupt: Bool = false, trailing: Bool = false) -> Data {
            let publicBlob = string(Data(keyType.utf8)) + string(outer)
            var privateBlob = u32(firstCheck) + u32(secondCheck)
                + string(Data("ssh-ed25519".utf8)) + string(inner)
                + string(privateSeed + suffix) + string(Data("test fixture".utf8))
            let padding = 8 - privateBlob.count % 8
            privateBlob.append(contentsOf: (1...padding).map { UInt8($0) })
            if paddingCorrupt { privateBlob[privateBlob.count - 1] = 0 }
            var payload = Data("openssh-key-v1\0".utf8)
                + string(Data("none".utf8)) + string(Data("none".utf8)) + string(Data())
                + u32(count) + string(publicBlob) + string(privateBlob)
            if trailing { payload.append(0) }
            // Keep the base64 and PEM valid so failures exercise binary validation.
            return Data(("-----BEGIN OPENSSH PRIVATE KEY-----\n"
                + payload.base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----\n").utf8)
        }
        let parsed = try OpenSSHPrivateKey.parse(wire())
        precondition(parsed == seed)
        let invalids = [
            wire(outer: otherKey), wire(inner: otherKey), wire(suffix: otherKey),
            wire(privateSeed: Data(repeating: 17, count: 32)), wire(secondCheck: 43),
            wire(keyType: "ssh-rsa"), wire(count: 2), wire(paddingCorrupt: true), wire(trailing: true)
        ]
        for (index, value) in invalids.enumerated() {
            do {
                _ = try OpenSSHPrivateKey.parse(value)
                preconditionFailure("Accepted inconsistent wire case \(index)")
            } catch is OpenSSHPrivateKeyError {}
        }
        let empty = Data()
        for value in [empty, Data(wire().prefix(80))] {
            do {
                _ = try OpenSSHPrivateKey.parse(value)
                preconditionFailure("Accepted truncated input")
            } catch is OpenSSHPrivateKeyError {}
        }
    }

    static func u32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
              UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    static func string(_ value: Data) -> Data { u32(UInt32(value.count)) + value }

    static func generateKey(at path: URL, passphrase: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", passphrase, "-f", path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }
}
