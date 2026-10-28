// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SSHKeysView: View {
    @EnvironmentObject private var keys: SSHKeyStore
    @State private var name = ""
    @State private var createdKey: SavedSSHKey?
    @State private var deletingKey: SavedSSHKey?
    @State private var showingDeleteConfirmation = false
    @State private var error: String?

    var body: some View {
        List {
            Section("Новый ключ Ed25519") {
                TextField("Название ключа, например iPhone", text: $name)
                    .serverTextInput()
                Button("Создать ключ") {
                    do {
                        createdKey = try keys.create(name: name)
                        name = ""
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Приватный ключ остаётся на этом устройстве. Для сервера скопируйте открытый ключ.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Мои ключи") {
                if keys.keys.isEmpty {
                    Text("Создайте ключ, чтобы скопировать его открытую часть и использовать для SSH-входа.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(keys.keys) { key in
                    NavigationLink {
                        SSHKeyDetailView(key: key)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(key.name)
                            Text(key.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    if let first = offsets.first {
                        deletingKey = keys.keys[first]
                        showingDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle("SSH-ключи")
        .navigationDestination(item: $createdKey) { SSHKeyDetailView(key: $0) }
        .confirmationDialog("Удалить ключ из списка?", isPresented: $showingDeleteConfirmation,
                            presenting: deletingKey) { key in
            Button("Удалить ключ", role: .destructive) {
                do { try keys.remove(key) } catch { self.error = error.localizedDescription }
                deletingKey = nil
            }
            Button("Отмена", role: .cancel) { deletingKey = nil }
        } message: { _ in
            Text("Сохранённые SSH-профили продолжат использовать свои копии ключа. Чтобы отозвать доступ, удалите открытый ключ на сервере.")
        }
        .alert("Ошибка SSH-ключа", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("ОК") { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct SSHKeyDetailView: View {
    @EnvironmentObject private var keys: SSHKeyStore
    let key: SavedSSHKey

    var body: some View {
        Form {
            Section("Открытый ключ") {
                if let publicKey = keys.publicKey(for: key.id) {
                    SSHPublicKeyView(publicKey: publicKey)
                } else {
                    Text(SSHKeyStoreError.missingKey.localizedDescription).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Вставьте открытый ключ в настройки SSH на сервере. Затем выберите этот ключ в профиле подключения: «Ключ Ed25519 → Мои ключи».")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Приватный ключ хранится в защищённом хранилище этого устройства и не копируется этой кнопкой.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(key.name)
    }
}

struct SSHPublicKeyView: View {
    let publicKey: String
    @State private var copied = false

    var body: some View {
        Text(publicKey).font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("SSH public key")
        Button(copied ? "Открытый ключ скопирован" : "Скопировать открытый ключ") {
            #if os(iOS)
            UIPasteboard.general.string = publicKey
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(publicKey, forType: .string)
            #endif
            copied = true
        }
    }
}
