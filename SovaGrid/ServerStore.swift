// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Crypto
import Foundation
import NIOSSH
import SwiftUI

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [SSHServer] = []
    private let defaultsKey = "sovagrid.ssh.servers.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SSHServer].self, from: data) {
            servers = decoded
        }
    }

    func add(name: String, host: String, port: Int, username: String, auth: SSHAuthKind, password: String,
             jumpHost: String = "", jumpPort: Int = 22, jumpUsername: String = "",
             jumpAuth: SSHAuthKind = .password, jumpPassword: String = "",
             targetPrivateKey: Data? = nil, jumpPrivateKey: Data? = nil) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty, (1...65535).contains(port) else {
            throw ServerStoreError.invalidAddress
        }
        guard auth != .password || !password.isEmpty else { throw ServerStoreError.emptyPassword }
        let trimmedJumpHost = jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJumpUser = jumpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let jump: SSHJumpHost?
        if trimmedJumpHost.isEmpty {
            jump = nil
        } else {
            guard !trimmedJumpUser.isEmpty, (1...65535).contains(jumpPort) else {
                throw ServerStoreError.invalidJumpAddress
            }
            guard jumpAuth != .password || !jumpPassword.isEmpty else { throw ServerStoreError.emptyJumpPassword }
            jump = SSHJumpHost(id: UUID(), host: trimmedJumpHost, port: jumpPort,
                               username: trimmedJumpUser, auth: jumpAuth)
        }

        let server = SSHServer(id: UUID(), name: name.isEmpty ? trimmedHost : name, host: trimmedHost,
                               port: port, username: trimmedUser, auth: auth, jump: jump)
        do {
            switch auth {
            case .password:
                try KeychainStore.set(password, for: KeychainStore.passwordAccount(server.id))
            case .ed25519:
                try KeychainStore.set(try privateKeyData(targetPrivateKey),
                                      for: KeychainStore.keyAccount(server.id))
            }
            if let jump {
                switch jump.auth {
                case .password:
                    try KeychainStore.set(jumpPassword, for: KeychainStore.passwordAccount(jump.id))
                case .ed25519:
                    try KeychainStore.set(try privateKeyData(jumpPrivateKey),
                                          for: KeychainStore.keyAccount(jump.id))
                }
            }
            servers.append(server)
            persist()
        } catch {
            KeychainStore.remove(KeychainStore.passwordAccount(server.id))
            KeychainStore.remove(KeychainStore.keyAccount(server.id))
            if let jump {
                KeychainStore.remove(KeychainStore.passwordAccount(jump.id))
                KeychainStore.remove(KeychainStore.keyAccount(jump.id))
            }
            throw error
        }
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let id = servers[index].id
            KeychainStore.remove(KeychainStore.passwordAccount(id))
            KeychainStore.remove(KeychainStore.keyAccount(id))
            KeychainStore.remove(KeychainStore.pinAccount(id))
            if let jump = servers[index].jump {
                KeychainStore.remove(KeychainStore.passwordAccount(jump.id))
                KeychainStore.remove(KeychainStore.keyAccount(jump.id))
                KeychainStore.remove(KeychainStore.pinAccount(jump.id))
            }
        }
        servers.remove(atOffsets: offsets)
        persist()
    }

    func publicKey(for server: SSHServer) -> String? {
        guard server.auth == .ed25519,
              let raw = KeychainStore.data(for: KeychainStore.keyAccount(server.id)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        return String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    func jumpPublicKey(for server: SSHServer) -> String? {
        guard let jump = server.jump, jump.auth == .ed25519,
              let raw = KeychainStore.data(for: KeychainStore.keyAccount(jump.id)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
        return String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func privateKeyData(_ imported: Data?) throws -> Data {
        guard let imported else { throw ServerStoreError.missingPrivateKey }
        guard imported.count == 32,
              (try? Curve25519.Signing.PrivateKey(rawRepresentation: imported)) != nil else {
            throw ServerStoreError.invalidPrivateKey
        }
        return imported
    }
}

enum ServerStoreError: LocalizedError {
    case invalidAddress
    case emptyPassword
    case invalidJumpAddress
    case emptyJumpPassword
    case missingPrivateKey
    case invalidPrivateKey

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Укажите адрес, пользователя и порт от 1 до 65535."
        case .emptyPassword: return "Введите SSH-пароль."
        case .invalidJumpAddress: return "Для промежуточного SSH-сервера укажите адрес, пользователя и порт от 1 до 65535."
        case .emptyJumpPassword: return "Введите SSH-пароль промежуточного сервера."
        case .missingPrivateKey: return "Создайте или выберите SSH-ключ до сохранения профиля."
        case .invalidPrivateKey: return "Импортированный ключ Ed25519 повреждён. Выберите файл снова."
        }
    }
}
