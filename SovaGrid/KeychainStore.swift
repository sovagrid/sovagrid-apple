// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation
import Security

enum KeychainFailure: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status): return "Ошибка Keychain: \(status)"
        }
    }
}

enum KeychainStore {
    private static let service = "com.sovagrid.app"

    static func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func set(_ data: Data, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainFailure.status(updateStatus) }

        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainFailure.status(addStatus) }
    }

    static func set(_ value: String, for account: String) throws {
        try set(Data(value.utf8), for: account)
    }

    static func remove(_ account: String) {
        try? delete(account)
    }

    static func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure.status(status)
        }
    }

    static func passwordAccount(_ id: UUID) -> String { "ssh.password.\(id.uuidString)" }
    static func keyAccount(_ id: UUID) -> String { "ssh.key.\(id.uuidString)" }
    static func savedKeyAccount(_ id: UUID) -> String { "ssh.library-key.\(id.uuidString)" }
    static func pinAccount(_ id: UUID) -> String { "ssh.pin.\(id.uuidString)" }
}
