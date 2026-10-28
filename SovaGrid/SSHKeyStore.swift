// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Crypto
import Foundation
import NIOSSH
import SwiftUI

struct SavedSSHKey: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let createdAt: Date
}

enum SSHKeyStoreError: LocalizedError {
    case invalidName
    case missingKey

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Введите название ключа от 1 до 80 символов."
        case .missingKey: return "Приватный ключ недоступен на этом устройстве. Выберите другой ключ или создайте новый."
        }
    }
}

@MainActor
final class SSHKeyStore: ObservableObject {
    @Published private(set) var keys: [SavedSSHKey] = []
    private let defaultsKey = "sovagrid.ssh.key-library.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedSSHKey].self, from: data) {
            keys = decoded
        }
    }

    @discardableResult
    func create(name: String) throws -> SavedSSHKey {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SSHKeyStoreError.invalidName
        }
        let record = SavedSSHKey(id: UUID(), name: name, createdAt: Date())
        let metadata = try JSONEncoder().encode(keys + [record])
        let privateKey = Curve25519.Signing.PrivateKey()
        // Only the seed enters Keychain. UserDefaults contains names, UUIDs and dates.
        try KeychainStore.set(privateKey.rawRepresentation, for: KeychainStore.savedKeyAccount(record.id))
        keys.append(record)
        UserDefaults.standard.set(metadata, forKey: defaultsKey)
        return record
    }

    func privateSeed(for id: UUID) throws -> Data {
        guard keys.contains(where: { $0.id == id }),
              let seed = KeychainStore.data(for: KeychainStore.savedKeyAccount(id)), seed.count == 32,
              (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)) != nil else {
            throw SSHKeyStoreError.missingKey
        }
        return seed
    }

    func publicKey(for id: UUID) -> String? {
        guard let seed = try? privateSeed(for: id),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        return String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    func remove(_ key: SavedSSHKey) throws {
        let remaining = keys.filter { $0.id != key.id }
        let metadata = try JSONEncoder().encode(remaining)
        try KeychainStore.delete(KeychainStore.savedKeyAccount(key.id))
        keys = remaining
        UserDefaults.standard.set(metadata, forKey: defaultsKey)
    }
}
