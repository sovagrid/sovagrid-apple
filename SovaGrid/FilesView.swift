// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

#if os(iOS)
private struct SFTPShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// A system share sheet retains the on-disk URL until the user finishes saving.
private struct SFTPShareSheet: UIViewControllerRepresentable {
    let file: URL
    let finished: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { finished() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

struct FilesView: View {
    @EnvironmentObject private var store: ServerStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var transfer = SFTPTransfer()
    @State private var selectedID: UUID?
    @State private var remotePath = "."
    @State private var importing = false
    #if os(iOS)
    @State private var shareFile: SFTPShareFile?
    #elseif os(macOS)
    @State private var saver = SFTPFileSaver()
    #endif

    private var server: SSHServer? {
        store.servers.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Picker("Сервер", selection: $selectedID) {
                        Text("Выберите сервер").tag(Optional<UUID>.none)
                        ForEach(store.servers) { server in
                            Text(server.name).tag(Optional(server.id))
                        }
                    }
                    HStack {
                        TextField("Папка на сервере", text: $remotePath)
                            .serverTextInput()
                            .onSubmit(openDirectory)
                        Button("Открыть", action: openDirectory)
                            .disabled(server == nil || transfer.busy)
                    }
                    HStack {
                        Button {
                            remotePath = parentPath(remotePath)
                            openDirectory()
                        } label: {
                            Label("Наверх", systemImage: "arrow.up")
                        }
                        .disabled(server == nil || transfer.busy)
                        Spacer()
                        Button {
                            importing = true
                        } label: {
                            Label("Загрузить файл", systemImage: "square.and.arrow.up")
                        }
                        .disabled(server == nil || transfer.busy)
                    }
                }
                .formStyle(.grouped)
                .frame(maxHeight: 245)

                if transfer.busy {
                    VStack(spacing: 8) {
                        ProgressView(transfer.status, value: transfer.progress)
                            .padding(.horizontal)
                        Button("Отменить передачу", role: .cancel) { transfer.cancel() }
                    }
                    .padding(.vertical, 8)
                } else {
                    Text(transfer.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                List(transfer.entries) { entry in
                    Button {
                        guard let server else { return }
                        do {
                            let path = try SFTPWire.joined(remotePath, entry.name)
                            if entry.isDirectory {
                                remotePath = path
                                transfer.list(on: server, path: path)
                            } else if entry.attributes.isRegularFile || entry.attributes.permissions == nil {
                                transfer.download(on: server, path: path, filename: entry.name)
                            }
                        } catch { transfer.errorMessage = error.localizedDescription }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).lineLimit(1)
                                if let size = entry.attributes.size, !entry.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: entry.isDirectory ? "chevron.right" : "square.and.arrow.down")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(transfer.busy || (!entry.isDirectory &&
                               !entry.attributes.isRegularFile && entry.attributes.permissions != nil))
                }
                .overlay {
                    if server == nil {
                        ContentUnavailableView("Выберите SSH-сервер", systemImage: "folder",
                                               description: Text("Для файлов используются сохранённые SSH-профили."))
                    } else if transfer.entries.isEmpty && !transfer.busy {
                        ContentUnavailableView("Папка пуста", systemImage: "folder",
                                               description: Text("Откройте папку или загрузите файл."))
                    }
                }
            }
            .navigationTitle("Файлы")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                guard let server else { return }
                switch result {
                case .success(let url): transfer.upload(on: server, localURL: url, directory: remotePath)
                case .failure: transfer.errorMessage = "Не удалось выбрать файл."
                }
            }
            .onChange(of: transfer.downloadedURL) { _, url in
                guard let url else { return }
                #if os(iOS)
                shareFile = SFTPShareFile(url: url)
                #elseif os(macOS)
                if !saver.present(url, completion: { transfer.clearDownloadedFile() }) {
                    transfer.errorMessage = "Не удалось открыть системное сохранение файла."
                    transfer.clearDownloadedFile()
                }
                #endif
            }
            .onChange(of: selectedID) { _, id in
                transfer.cancel()
                remotePath = "."
                if let server = store.servers.first(where: { $0.id == id }) {
                    transfer.list(on: server, path: remotePath)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    transfer.cancel()
                }
            }
            #if os(iOS)
            .sheet(item: $shareFile, onDismiss: { transfer.clearDownloadedFile() }) { item in
                SFTPShareSheet(file: item.url, finished: { shareFile = nil })
            }
            #endif
            .alert("Новый ключ сервера", isPresented: Binding(
                get: { transfer.hostChallenge != nil }, set: { _ in })) {
                Button("Доверять") { transfer.acceptHostKey(true) }
                Button("Отмена", role: .cancel) { transfer.acceptHostKey(false) }
            } message: {
                Text("\(transfer.hostChallenge?.address ?? "")\nSHA256:\(transfer.hostChallenge?.fingerprint ?? "")\nСверьте отпечаток с администратором сервера.")
            }
            .alert("Ошибка SFTP", isPresented: Binding(
                get: { transfer.errorMessage != nil },
                set: { if !$0 { transfer.errorMessage = nil } })) {
                Button("ОК") { transfer.errorMessage = nil }
            } message: { Text(transfer.errorMessage ?? "") }
        }
        .onDisappear {
            transfer.cancel()
        }
    }

    private func openDirectory() {
        guard let server else { return }
        transfer.list(on: server, path: remotePath)
    }

    private func parentPath(_ path: String) -> String {
        if path.isEmpty || path == "." { return ".." }
        let components = path.split(separator: "/").dropLast()
        if path.hasPrefix("/") {
            return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        }
        return components.isEmpty ? "." : components.joined(separator: "/")
    }
}
