// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SwiftUI

enum SFTPTemporaryFiles {
    private static let prefix = "SovaGrid-SFTP-"

    static func directory(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + id.uuidString, isDirectory: true)
    }

    static func removeStaleAtLaunch() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix),
                  UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let properties = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}

@MainActor
final class SFTPTransfer: ObservableObject {
    @Published private(set) var status = "Выберите сервер и откройте папку."
    @Published private(set) var busy = false
    @Published private(set) var progress: Double?
    @Published private(set) var entries: [SFTPFileEntry] = []
    @Published private(set) var downloadedURL: URL?
    @Published var hostChallenge: HostKeyChallenge?
    @Published var errorMessage: String?

    private var group: MultiThreadedEventLoopGroup?
    private var parent: Channel?
    private var operationID: UUID?
    private var localFile: FileHandle?
    private var scopedURL: URL?
    private var scopedAccess = false
    private var temporaryDirectory: URL?
    private var transportReady = false
    private var uploadMayLeavePartial = false

    func list(on server: SSHServer, path: String) {
        do {
            _ = try SFTPWire.path(path)
            begin(on: server, job: .list(path: path), description: "Чтение папки…")
        } catch { show(error) }
    }

    func upload(on server: SSHServer, localURL: URL, directory: String) {
        guard !busy else { return }
        do {
            let remote = try SFTPWire.joined(directory, localURL.lastPathComponent)
            let granted = localURL.startAccessingSecurityScopedResource()
            do {
                let resource = try localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resource.isRegularFile == true, let size = resource.fileSize, size >= 0,
                      UInt64(size) <= SFTPWire.maximumFileBytes else { throw SFTPWireError.tooLarge }
                let file = try FileHandle(forReadingFrom: localURL)
                scopedURL = localURL
                scopedAccess = granted
                localFile = file
                begin(on: server, job: .upload(local: file, size: UInt64(size), remotePath: remote),
                      description: "Загрузка \(localURL.lastPathComponent)…")
            } catch {
                if granted { localURL.stopAccessingSecurityScopedResource() }
                throw error
            }
        } catch { show(error) }
    }

    func download(on server: SSHServer, path: String, filename: String) {
        guard !busy else { return }
        do {
            _ = try SFTPWire.path(path)
            guard filename == URL(fileURLWithPath: filename).lastPathComponent,
                  filename != ".", filename != ".." else { throw SFTPWireError.invalidPath }
            let directory = SFTPTemporaryFiles.directory(for: UUID())
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            temporaryDirectory = directory
            let output = directory.appendingPathComponent(filename, isDirectory: false)
            guard FileManager.default.createFile(
                atPath: output.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw SFTPWireError.malformed }
            let file = try FileHandle(forWritingTo: output)
            localFile = file
            begin(on: server, job: .download(local: file, localURL: output, remotePath: path),
                  description: "Скачивание \(filename)…")
        } catch {
            clearTemporaryDownload()
            show(error)
        }
    }

    func acceptHostKey(_ accepted: Bool) {
        let challenge = hostChallenge
        hostChallenge = nil
        challenge?.resolve(accepted)
    }

    func cancel() {
        guard busy else { return }
        if hostChallenge != nil { acceptHostKey(false) }
        operationID = nil
        busy = false
        status = uploadMayLeavePartial
            ? "Операция отменена. На сервере может остаться неполный файл."
            : "Операция отменена."
        uploadMayLeavePartial = false
        progress = nil
        closeLocalFile()
        clearTemporaryDownload()
        stopTransport()
    }

    func clearDownloadedFile() {
        downloadedURL = nil
        clearTemporaryDownload()
    }

    private func begin(on server: SSHServer, job: SFTPJob, description: String) {
        guard !busy else { return }
        let id = UUID()
        operationID = id
        transportReady = false
        if case .upload = job { uploadMayLeavePartial = true }
        else { uploadMayLeavePartial = false }
        errorMessage = nil
        status = description
        busy = true
        progress = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.operationID == id, !self.transportReady,
                  self.hostChallenge == nil else { return }
            self.finish(.failure(SFTPWireError.timedOut), id: id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20 * 60) { [weak self] in
            guard let self, self.operationID == id else { return }
            self.finish(.failure(SFTPWireError.timedOut), id: id)
        }

        let targetAuth: ClientAuthDelegate
        let entryAuth: ClientAuthDelegate
        do {
            targetAuth = try makeAuth(id: server.id, username: server.username, kind: server.auth)
            if let jump = server.jump {
                entryAuth = try makeAuth(id: jump.id, username: jump.username, kind: jump.auth)
            } else {
                entryAuth = targetAuth
            }
        } catch {
            finish(.failure(error), id: id)
            return
        }

        let askHost: (String, String, @escaping (Bool) -> Void) -> Void = { [weak self] address, fingerprint, answer in
            DispatchQueue.main.async {
                guard let self, self.operationID == id else {
                    answer(false)
                    return
                }
                self.hostChallenge = HostKeyChallenge(fingerprint: fingerprint, address: address, resolve: answer)
            }
        }
        let entryHost = server.jump?.host ?? server.host
        let entryPort = server.jump?.port ?? server.port
        let entryID = server.jump?.id ?? server.id
        let entryHostAuth = HostKeyDelegate(id: entryID, address: "\(entryHost):\(entryPort)", challenge: askHost)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: entryAuth, serverAuthDelegate: entryHostAuth)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
        bootstrap.connect(host: entryHost, port: entryPort).whenComplete { [weak self] result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self?.finish(.failure(error), id: id) }
            case .success(let channel):
                DispatchQueue.main.async {
                    guard let self, self.operationID == id else {
                        channel.close(promise: nil)
                        return
                    }
                    self.parent = channel
                }
                channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                    switch result {
                    case .failure(let error):
                        DispatchQueue.main.async { self?.finish(.failure(error), id: id) }
                    case .success(let ssh):
                        if server.jump == nil {
                            DispatchQueue.main.async {
                                self?.openSFTP(using: ssh, transport: channel, job: job, id: id)
                            }
                        } else {
                            DispatchQueue.main.async {
                                self?.openNested(server: server, entry: channel, ssh: ssh,
                                                 auth: targetAuth, challenge: askHost, job: job, id: id)
                            }
                        }
                    }
                }
            }
        }
    }

    private func openNested(server: SSHServer, entry: Channel, ssh: NIOSSHHandler,
                            auth: ClientAuthDelegate,
                            challenge: @escaping (String, String, @escaping (Bool) -> Void) -> Void,
                            job: SFTPJob, id: UUID) {
        guard let origin = entry.localAddress else {
            DispatchQueue.main.async { self.finish(.failure(SFTPWireError.unexpectedResponse), id: id) }
            return
        }
        let targetHostAuth = HostKeyDelegate(
            id: server.id, address: "\(server.host):\(server.port)", challenge: challenge)
        let direct = SSHChannelType.DirectTCPIP(
            targetHost: server.host, targetPort: server.port, originatorAddress: origin)
        let promise = entry.eventLoop.makePromise(of: Channel.self)
        entry.eventLoop.execute {
            ssh.createChannel(promise, channelType: .directTCPIP(direct)) { tunnel, type in
                guard case .directTCPIP = type else {
                    return tunnel.eventLoop.makeFailedFuture(SFTPWireError.unexpectedResponse)
                }
                return tunnel.eventLoop.makeCompletedFuture {
                    let nested = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: targetHostAuth)),
                        allocator: tunnel.allocator, inboundChildChannelInitializer: nil)
                    try tunnel.pipeline.syncOperations.addHandler(SSHStreamWrapper())
                    try tunnel.pipeline.syncOperations.addHandler(nested)
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self?.finish(.failure(error), id: id) }
            case .success(let tunnel):
                tunnel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { nestedResult in
                    switch nestedResult {
                    case .failure(let error):
                        DispatchQueue.main.async { self?.finish(.failure(error), id: id) }
                    case .success(let nested):
                        DispatchQueue.main.async {
                            self?.openSFTP(using: nested, transport: tunnel, job: job, id: id)
                        }
                    }
                }
            }
        }
    }

    private func openSFTP(using ssh: NIOSSHHandler, transport: Channel, job: SFTPJob, id: UUID) {
        let promise = transport.eventLoop.makePromise(of: Channel.self)
        let wire = SFTPChannelHandler()
        transport.eventLoop.execute {
            ssh.createChannel(promise) { child, type in
                guard type == .session else { return child.eventLoop.makeFailedFuture(SFTPWireError.unexpectedResponse) }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(wire)
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self?.finish(.failure(error), id: id) }
            case .success(let child):
                wire.start(on: child).flatMap {
                    DispatchQueue.main.async {
                        guard self?.operationID == id else { return }
                        self?.transportReady = true
                    }
                    let client = SFTPClient(wire: wire, loop: child.eventLoop) { [weak self] current, total in
                        DispatchQueue.main.async {
                            guard self?.operationID == id else { return }
                            self?.progress = total.map { $0 == 0 ? 1 : Double(current) / Double($0) }
                            self?.status = total.map { "\(ByteCountFormatter.string(fromByteCount: Int64(current), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" }
                                ?? "\(ByteCountFormatter.string(fromByteCount: Int64(current), countStyle: .file)) передано"
                        }
                    }
                    return client.perform(job)
                }.whenComplete { [weak self] result in
                    child.close(promise: nil)
                    DispatchQueue.main.async { self?.finish(result, id: id) }
                }
            }
        }
    }

    private func makeAuth(id: UUID, username: String, kind: SSHAuthKind) throws -> ClientAuthDelegate {
        switch kind {
        case .password:
            guard let password = KeychainStore.string(for: KeychainStore.passwordAccount(id)) else {
                throw SSHSessionError.missingSecret
            }
            return ClientAuthDelegate(username: username, password: password, privateKey: nil)
        case .ed25519:
            guard let raw = KeychainStore.data(for: KeychainStore.keyAccount(id)),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
                throw SSHSessionError.missingSecret
            }
            return ClientAuthDelegate(username: username, password: nil,
                                      privateKey: NIOSSHPrivateKey(ed25519Key: key))
        }
    }

    private func finish(_ result: Result<SFTPOutcome, Error>, id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        busy = false
        uploadMayLeavePartial = false
        progress = nil
        closeLocalFile()
        switch result {
        case .success(.listing(let files)):
            entries = files.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            status = "\(entries.count) объектов"
        case .success(.uploaded):
            status = "Файл загружен."
        case .success(.downloaded(let url)):
            downloadedURL = url
            status = "Файл скачан. Выберите, куда сохранить."
        case .failure(let error):
            show(error)
            clearTemporaryDownload()
        }
        stopTransport()
    }

    private func show(_ error: Error) {
        if let safe = error as? SFTPWireError { errorMessage = safe.localizedDescription }
        else if let safe = error as? SSHSessionError { errorMessage = safe.localizedDescription }
        else { errorMessage = "Не удалось завершить операцию. Проверьте соединение и права доступа." }
        status = "Ошибка"
    }

    private func closeLocalFile() {
        try? localFile?.close()
        localFile = nil
        if scopedAccess { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedURL = nil
        scopedAccess = false
    }

    private func clearTemporaryDownload() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
    }

    private func stopTransport() {
        let oldParent = parent
        parent = nil
        let oldGroup = group
        group = nil
        if let oldParent {
            oldParent.close().whenComplete { _ in
                DispatchQueue.global(qos: .utility).async { try? oldGroup?.syncShutdownGracefully() }
            }
        } else {
            DispatchQueue.global(qos: .utility).async { try? oldGroup?.syncShutdownGracefully() }
        }
    }
}
