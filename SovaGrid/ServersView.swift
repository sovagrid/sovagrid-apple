// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ServersView: View {
    @EnvironmentObject private var store: ServerStore
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if store.servers.isEmpty {
                    ContentUnavailableView("Нет SSH-серверов", systemImage: "terminal", description: Text("Добавьте сервер, чтобы открыть терминал."))
                }
                ForEach(store.servers) { server in
                    NavigationLink {
                        TerminalScreen(server: server, publicKey: store.publicKey(for: server),
                                       jumpPublicKey: store.jumpPublicKey(for: server))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name).font(.headline)
                            Text(server.address).font(.subheadline).foregroundStyle(.secondary)
                            if let jump = server.jump {
                                Text("Через \(jump.address)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(server.auth.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .onDelete(perform: store.remove)
            }
            .navigationTitle("SSH-серверы")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        SSHKeysView()
                    } label: { Label("SSH-ключи", systemImage: "key") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Добавить сервер")
                }
            }
            .sheet(isPresented: $showingAdd) { AddServerView() }
        }
    }
}

struct AddServerView: View {
    private enum KeySource: String, CaseIterable, Identifiable {
        case generated = "Создать новый"
        case saved = "Мои ключи"
        case imported = "Импортировать"
        var id: String { rawValue }
    }
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var keys: SSHKeyStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var auth: SSHAuthKind = .password
    @State private var password = ""
    @State private var viaJump = false
    @State private var jumpHost = ""
    @State private var jumpPort = "22"
    @State private var jumpUsername = ""
    @State private var jumpAuth: SSHAuthKind = .password
    @State private var jumpPassword = ""
    @State private var targetImportedKey: Data?
    @State private var targetKeySource: KeySource = .generated
    @State private var targetSavedKeyID: UUID?
    @State private var targetKeyName = ""
    @State private var jumpImportedKey: Data?
    @State private var jumpKeySource: KeySource = .generated
    @State private var jumpSavedKeyID: UUID?
    @State private var jumpKeyName = ""
    @State private var importingKey = false
    @State private var importingJumpKey = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Подключение") {
                    TextField("Название", text: $name)
                    TextField("Адрес или IP", text: $host)
                        .serverTextInput()
                    TextField("Порт", text: $port).serverNumberInput()
                    TextField("Пользователь", text: $username)
                        .serverTextInput()
                }
                Section("SSH-вход") {
                    Picker("Способ", selection: $auth) {
                        ForEach(SSHAuthKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                    }
                    if auth == .password {
                        SecureField("SSH-пароль", text: $password)
                    } else {
                        Picker("Ключ сервера", selection: $targetKeySource) {
                            ForEach(KeySource.allCases) { source in Text(source.rawValue).tag(source) }
                        }
                        if targetKeySource == .saved {
                            Picker("Мой ключ сервера", selection: $targetSavedKeyID) {
                                Text("Выберите ключ").tag(nil as UUID?)
                                ForEach(keys.keys) { key in Text(key.name).tag(Optional(key.id)) }
                            }
                            if let id = targetSavedKeyID, let publicKey = keys.publicKey(for: id) {
                                SSHPublicKeyView(publicKey: publicKey)
                            }
                            NavigationLink("Создать SSH-ключ") { SSHKeysView() }
                        }
                        if targetKeySource == .imported {
                            Button("Выбрать приватный ключ OpenSSH") {
                                importingJumpKey = false
                                importingKey = true
                            }
                            if targetImportedKey != nil {
                                Label("Выбран ключ: \(targetKeyName)", systemImage: "checkmark.shield")
                                    .font(.footnote)
                            }
                        }
                        if targetKeySource == .generated {
                            Button("Создать ключ") { createKey(forJump: false) }
                            Text("Создайте ключ, чтобы сразу скопировать его открытую часть. При сохранении без этой кнопки будет создан отдельный ключ профиля.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if targetKeySource == .imported {
                            Text("Выберите существующий ключ OpenSSH Ed25519 без парольной фразы. Его открытый ключ должен быть уже разрешён на сервере.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Промежуточный SSH-сервер") {
                    Toggle("Подключаться через SSH", isOn: $viaJump)
                    if viaJump {
                        Text("Адрес назначения определяется с промежуточного сервера. Для локального порта на нём можно указать, например, 127.0.0.1:2200.")
                            .font(.footnote).foregroundStyle(.secondary)
                        TextField("Адрес перехода", text: $jumpHost).serverTextInput()
                        TextField("Порт перехода", text: $jumpPort).serverNumberInput()
                        TextField("Пользователь перехода", text: $jumpUsername).serverTextInput()
                        Picker("Вход на переходе", selection: $jumpAuth) {
                            ForEach(SSHAuthKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                        }
                        if jumpAuth == .password {
                            SecureField("SSH-пароль перехода", text: $jumpPassword)
                        } else {
                            Picker("Ключ перехода", selection: $jumpKeySource) {
                                ForEach(KeySource.allCases) { source in Text(source.rawValue).tag(source) }
                            }
                            if jumpKeySource == .saved {
                                Picker("Мой ключ перехода", selection: $jumpSavedKeyID) {
                                    Text("Выберите ключ").tag(nil as UUID?)
                                    ForEach(keys.keys) { key in Text(key.name).tag(Optional(key.id)) }
                                }
                                if let id = jumpSavedKeyID, let publicKey = keys.publicKey(for: id) {
                                    SSHPublicKeyView(publicKey: publicKey)
                                }
                                NavigationLink("Создать SSH-ключ перехода") { SSHKeysView() }
                            }
                            if jumpKeySource == .imported {
                                Button("Выбрать ключ промежуточного сервера") {
                                    importingJumpKey = true
                                    importingKey = true
                                }
                                if jumpImportedKey != nil {
                                    Label("Выбран ключ: \(jumpKeyName)", systemImage: "checkmark.shield")
                                        .font(.footnote)
                                }
                            }
                            if jumpKeySource == .generated {
                                Button("Создать ключ перехода") { createKey(forJump: true) }
                                Text("Создайте ключ, чтобы скопировать открытую часть для промежуточного сервера.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if jumpKeySource == .imported {
                                Text("Выберите ключ OpenSSH Ed25519 без парольной фразы, разрешённый на промежуточном сервере.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Новый сервер")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { clearSecrets(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { save() } }
            }
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    do {
                        let seed = try OpenSSHPrivateKey.importSeed(from: url)
                        if importingJumpKey {
                            jumpImportedKey = seed
                            jumpKeyName = url.lastPathComponent
                        } else {
                            targetImportedKey = seed
                            targetKeyName = url.lastPathComponent
                        }
                    } catch { self.error = error.localizedDescription }
                case .failure(let failure):
                    if (failure as? CocoaError)?.code != .userCancelled {
                        error = "Не удалось открыть выбранный SSH-ключ."
                    }
                }
            }
            .alert("Ошибка ключа или профиля", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("ОК") { error = nil }
            } message: { Text(error ?? "") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                clearSecrets()
            }
        }
        .onChange(of: targetKeySource) { _, source in
            if source != .imported { targetImportedKey = nil; targetKeyName = "" }
        }
        .onChange(of: jumpKeySource) { _, source in
            if source != .imported { jumpImportedKey = nil; jumpKeyName = "" }
        }
    }

    private func save() {
        if viaJump && jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            error = ServerStoreError.invalidJumpAddress.localizedDescription
            return
        }
        if auth == .ed25519 && targetKeySource == .imported && targetImportedKey == nil {
            error = "Выберите приватный ключ сервера. После ухода в фон файл нужно выбрать снова."
            return
        }
        if viaJump && jumpAuth == .ed25519 && jumpKeySource == .imported && jumpImportedKey == nil {
            error = "Выберите приватный ключ промежуточного сервера. После ухода в фон файл нужно выбрать снова."
            return
        }
        do {
            let targetKey = auth == .ed25519
                ? try selectedKey(source: targetKeySource, imported: targetImportedKey, savedID: targetSavedKeyID) : nil
            let jumpKey = viaJump && jumpAuth == .ed25519
                ? try selectedKey(source: jumpKeySource, imported: jumpImportedKey, savedID: jumpSavedKeyID) : nil
            try store.add(name: name, host: host, port: Int(port) ?? 0, username: username, auth: auth, password: password,
                          jumpHost: viaJump ? jumpHost : "", jumpPort: Int(jumpPort) ?? 0,
                          jumpUsername: jumpUsername, jumpAuth: jumpAuth, jumpPassword: jumpPassword,
                          targetPrivateKey: auth == .ed25519 ? targetKey : nil,
                          jumpPrivateKey: jumpKey)
            clearSecrets()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func selectedKey(source: KeySource, imported: Data?, savedID: UUID?) throws -> Data? {
        switch source {
        case .generated: return nil
        case .imported: return imported
        case .saved:
            guard let savedID else { throw SSHKeyStoreError.missingKey }
            return try keys.privateSeed(for: savedID)
        }
    }

    private func createKey(forJump: Bool) {
        do {
            let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = try keys.create(name: base.isEmpty
                ? (forJump ? "Ключ промежуточного сервера" : "Ключ сервера")
                : String(base.prefix(60)) + (forJump ? " · переход" : " · сервер"))
            if forJump {
                jumpSavedKeyID = record.id
                jumpKeySource = .saved
            } else {
                targetSavedKeyID = record.id
                targetKeySource = .saved
            }
        } catch { self.error = error.localizedDescription }
    }

    private func clearSecrets() {
        password = ""
        jumpPassword = ""
        targetImportedKey = nil
        jumpImportedKey = nil
        targetKeyName = ""
        jumpKeyName = ""
    }
}

struct TerminalScreen: View {
    let server: SSHServer
    let publicKey: String?
    let jumpPublicKey: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = SSHSession()
    @State private var showPublicKey = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(session.status.hasPrefix("Подключено") ? .green : .orange).frame(width: 8, height: 8)
                Text(session.status).font(.caption).lineLimit(1)
                Spacer()
                if session.status == "Отключено" {
                    Button("Подключить") { session.connect(to: server) }.font(.caption)
                }
                Button("Ctrl-C") { session.send([3]) }.font(.caption)
                    .disabled(!session.status.hasPrefix("Подключено"))
            }
            .padding(.horizontal)
            .padding(.vertical, 9)
            TerminalBridge(session: session)
                .background(colorScheme == .dark
                            ? Color(red: 0.05, green: 0.07, blue: 0.11)
                            : Color(red: 0.98, green: 0.985, blue: 1))
        }
        .navigationTitle(server.name)
        .toolbar {
            if publicKey != nil || jumpPublicKey != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(jumpPublicKey == nil ? "Открытый ключ" : "SSH-ключи") { showPublicKey = true }
                }
            }
        }
        .sheet(isPresented: $showPublicKey) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let publicKey {
                            Text("Ключ сервера назначения").font(.headline)
                            Text(publicKey).font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            Button(jumpPublicKey == nil ? "Скопировать" : "Скопировать ключ назначения") {
                                copy(publicKey)
                            }
                        }
                        if let jumpPublicKey {
                            Text("Ключ промежуточного сервера").font(.headline)
                            Text(jumpPublicKey).font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            Button("Скопировать ключ перехода") {
                                copy(jumpPublicKey)
                            }
                        }
                    }
                    .padding()
                }
                .navigationTitle("SSH-ключи")
            }
        }
        .alert("Новый ключ сервера", isPresented: Binding(get: { session.hostChallenge != nil }, set: { _ in })) {
            Button("Доверять") { session.acceptHostKey(true) }
            Button("Отмена", role: .cancel) { session.acceptHostKey(false) }
        } message: {
            Text("\(session.hostChallenge?.address ?? "")\nSHA256:\(session.hostChallenge?.fingerprint ?? "")\nСверьте отпечаток с администратором сервера перед подтверждением.")
        }
        .alert("SSH-ошибка", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("ОК") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
        .task { session.connect(to: server) }
        .onDisappear { session.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.disconnect() }
        }
    }

    private func copy(_ key: String) {
        #if os(iOS)
        UIPasteboard.general.string = key
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        #endif
    }
}

extension View {
    @ViewBuilder func serverTextInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }

    @ViewBuilder func serverNumberInput() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
