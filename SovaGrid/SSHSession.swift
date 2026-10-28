// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SwiftUI

enum SSHSessionError: LocalizedError {
    case missingSecret
    case unsupportedAuthentication
    case rejectedShell
    case rejectedHost
    case changedHost(expected: String, received: String)
    case invalidHostKey

    var errorDescription: String? {
        switch self {
        case .missingSecret: return "Пароль или приватный ключ не найден в Keychain."
        case .unsupportedAuthentication: return "Сервер не поддерживает выбранный способ SSH-входа."
        case .rejectedShell: return "Сервер отклонил запрос PTY или интерактивной оболочки."
        case .rejectedHost: return "Ключ сервера не был принят."
        case .changedHost(let expected, let received):
            return "Ключ сервера изменился. Ожидался SHA256:\(expected), получен SHA256:\(received). Подключение заблокировано."
        case .invalidHostKey: return "Не удалось прочитать ключ SSH-сервера."
        }
    }
}

struct HostKeyChallenge: Identifiable {
    let id = UUID()
    let fingerprint: String
    let address: String
    let resolve: (Bool) -> Void
}

// NIO invokes this delegate on one event loop. Its mutable attempt state never crosses loops.
final class ClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var password: String?
    private var privateKey: NIOSSHPrivateKey?
    private var attempted = false

    init(username: String, password: String?, privateKey: NIOSSHPrivateKey?) {
        self.username = username
        self.password = password
        self.privateKey = privateKey
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !attempted else {
            nextChallengePromise.succeed(nil)
            return
        }
        attempted = true
        if let privateKey, availableMethods.contains(.publicKey) {
            self.privateKey = nil
            nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: privateKey))))
        } else if let password, availableMethods.contains(.password) {
            self.password = nil
            nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: password))))
        } else {
            nextChallengePromise.fail(SSHSessionError.unsupportedAuthentication)
        }
    }
}

final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let id: UUID
    private let address: String
    private let challenge: (String, String, @escaping (Bool) -> Void) -> Void

    init(id: UUID, address: String, challenge: @escaping (String, String, @escaping (Bool) -> Void) -> Void) {
        self.id = id
        self.address = address
        self.challenge = challenge
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let serialized = String(openSSHPublicKey: hostKey)
        let pieces = serialized.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, let blob = Data(base64Encoded: String(pieces[1])) else {
            validationCompletePromise.fail(SSHSessionError.invalidHostKey)
            return
        }
        let fingerprint = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let account = KeychainStore.pinAccount(id)
        if let known = KeychainStore.string(for: account) {
            if known == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHSessionError.changedHost(expected: known, received: fingerprint))
            }
            return
        }

        challenge(address, fingerprint) { trusted in
            guard trusted else {
                validationCompletePromise.fail(SSHSessionError.rejectedHost)
                return
            }
            do {
                try KeychainStore.set(fingerprint, for: account)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }
}

/// Lets a second SSH handshake run directly inside a bastion's direct-tcpip channel.
final class SSHStreamWrapper: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let buffer) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

private final class SSHOutputHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let output: ([UInt8]) -> Void
    private let ready: () -> Void
    private let failure: (Error) -> Void
    private let closed: () -> Void
    private var acceptedRequests = 0

    init(output: @escaping ([UInt8]) -> Void, ready: @escaping () -> Void,
         failure: @escaping (Error) -> Void, closed: @escaping () -> Void) {
        self.output = output
        self.ready = ready
        self.failure = failure
        self.closed = closed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        if case .byteBuffer(let buffer) = message.data {
            output(Array(buffer.readableBytesView))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failure(error)
        context.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            acceptedRequests += 1
            if acceptedRequests == 2 { ready() }
        } else if event is ChannelFailureEvent {
            failure(SSHSessionError.rejectedShell)
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closed()
        context.fireChannelInactive()
    }
}

private final class SSHParentErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let failure: (Error) -> Void
    init(failure: @escaping (Error) -> Void) { self.failure = failure }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failure(error)
        context.close(promise: nil)
    }
}

@MainActor
final class SSHSession: ObservableObject {
    @Published private(set) var status = "Отключено"
    @Published var errorMessage: String?
    @Published var hostChallenge: HostKeyChallenge?
    var onOutput: (([UInt8]) -> Void)?

    private var group: MultiThreadedEventLoopGroup?
    private var parent: Channel?
    private var shell: Channel?
    private var connected = false
    private var connectionID: UUID?
    private var terminalColumns = 80
    private var terminalRows = 24

    func connect(to server: SSHServer) {
        guard group == nil else { return }
        let id = UUID()
        connectionID = id
        errorMessage = nil
        status = "Подключение…"

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
            fail(error, for: id)
            return
        }

        let askHost: (String, String, @escaping (Bool) -> Void) -> Void = { [weak self] address, fingerprint, answer in
            DispatchQueue.main.async {
                guard let self, self.connectionID == id else {
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
        let initialColumns = terminalColumns
        let initialRows = terminalRows

        let openShell: (NIOSSHHandler, Channel) -> Void = { [weak self] handler, transport in
            let promise = transport.eventLoop.makePromise(of: Channel.self)
            handler.createChannel(promise) { child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(SSHSessionError.unsupportedAuthentication)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SSHOutputHandler(output: { bytes in
                        DispatchQueue.main.async {
                            guard self?.connectionID == id else { return }
                            self?.onOutput?(bytes)
                        }
                    }, ready: {
                        DispatchQueue.main.async {
                            guard self?.connectionID == id else { return }
                            self?.shell = child
                            self?.connected = true
                            self?.status = "Подключено: \(server.address)"
                            if let self {
                                self.resize(columns: self.terminalColumns, rows: self.terminalRows)
                            }
                        }
                    }, failure: { error in
                        DispatchQueue.main.async { self?.fail(error, for: id) }
                    }, closed: {
                        DispatchQueue.main.async {
                            guard self?.connectionID == id else { return }
                            self?.disconnect()
                        }
                    }))
                }
            }
            promise.futureResult.whenComplete { childResult in
                switch childResult {
                case .failure(let error):
                    DispatchQueue.main.async { self?.fail(error, for: id) }
                case .success(let child):
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenComplete { _ in
                        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                            wantReply: true, term: "xterm-256color", terminalCharacterWidth: initialColumns,
                            terminalRowHeight: initialRows, terminalPixelWidth: 0, terminalPixelHeight: 0,
                            terminalModes: SSHTerminalModes([:]))
                        child.triggerUserOutboundEvent(pty).flatMap {
                            child.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
                        }.whenFailure { error in
                            DispatchQueue.main.async { self?.fail(error, for: id) }
                        }
                    }
                }
            }
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = eventLoopGroup
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(role: .client(.init(userAuthDelegate: entryAuth, serverAuthDelegate: entryHostAuth)),
                                            allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(SSHParentErrorHandler { error in
                        DispatchQueue.main.async { self?.fail(error, for: id) }
                    })
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        bootstrap.connect(host: entryHost, port: entryPort).whenComplete { [weak self] result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self?.fail(error, for: id) }
            case .success(let channel):
                DispatchQueue.main.async {
                    guard self?.connectionID == id else {
                        channel.close(promise: nil)
                        return
                    }
                    self?.parent = channel
                }
                channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                    switch result {
                    case .failure(let error):
                        DispatchQueue.main.async { self?.fail(error, for: id) }
                    case .success(let handler):
                        guard server.jump != nil else {
                            openShell(handler, channel)
                            return
                        }
                        guard let origin = channel.localAddress else {
                            DispatchQueue.main.async { self?.fail(SSHSessionError.invalidHostKey, for: id) }
                            return
                        }
                        let direct = SSHChannelType.DirectTCPIP(
                            targetHost: server.host, targetPort: server.port, originatorAddress: origin)
                        let promise = channel.eventLoop.makePromise(of: Channel.self)
                        let targetHostAuth = HostKeyDelegate(
                            id: server.id, address: "\(server.host):\(server.port)", challenge: askHost)
                        handler.createChannel(promise, channelType: .directTCPIP(direct)) { tunnel, type in
                            guard case .directTCPIP = type else {
                                return tunnel.eventLoop.makeFailedFuture(SSHSessionError.unsupportedAuthentication)
                            }
                            return tunnel.eventLoop.makeCompletedFuture {
                                let nested = NIOSSHHandler(
                                    role: .client(.init(userAuthDelegate: targetAuth, serverAuthDelegate: targetHostAuth)),
                                    allocator: tunnel.allocator, inboundChildChannelInitializer: nil)
                                try tunnel.pipeline.syncOperations.addHandler(SSHStreamWrapper())
                                try tunnel.pipeline.syncOperations.addHandler(nested)
                                try tunnel.pipeline.syncOperations.addHandler(SSHParentErrorHandler { error in
                                    DispatchQueue.main.async { self?.fail(error, for: id) }
                                })
                            }
                        }
                        promise.futureResult.whenComplete { tunnelResult in
                            switch tunnelResult {
                            case .failure(let error):
                                DispatchQueue.main.async { self?.fail(error, for: id) }
                            case .success(let tunnel):
                                tunnel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { nestedResult in
                                    switch nestedResult {
                                    case .failure(let error):
                                        DispatchQueue.main.async { self?.fail(error, for: id) }
                                    case .success(let nested):
                                        openShell(nested, tunnel)
                                    }
                                }
                            }
                        }
                    }
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

    func send(_ bytes: [UInt8]) {
        guard connected, let shell, let id = connectionID else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        shell.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).whenFailure { [weak self] error in
            DispatchQueue.main.async { self?.fail(error, for: id) }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        terminalColumns = columns
        terminalRows = rows
        guard connected, let shell, let id = connectionID else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: columns,
                                                               terminalRowHeight: rows,
                                                               terminalPixelWidth: 0, terminalPixelHeight: 0)
        shell.triggerUserOutboundEvent(event).whenFailure { [weak self] error in
            DispatchQueue.main.async { self?.fail(error, for: id) }
        }
    }

    func acceptHostKey(_ accepted: Bool) {
        let challenge = hostChallenge
        hostChallenge = nil
        challenge?.resolve(accepted)
    }

    func disconnect() {
        if hostChallenge != nil { acceptHostKey(false) }
        connectionID = nil
        connected = false
        status = "Отключено"
        shell = nil
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

    private func fail(_ error: Error, for id: UUID) {
        guard connectionID == id else { return }
        if errorMessage == nil { errorMessage = error.localizedDescription }
        disconnect()
    }
}
