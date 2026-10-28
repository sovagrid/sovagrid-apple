// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SwiftUI

private enum PanelTunnelError: LocalizedError {
    case noOriginAddress
    case noLocalPort
    case invalidChannel
    case connectionClosed
    case connectionTimedOut
    case webPolicy
    case panelLocation

    var errorDescription: String? {
        switch self {
        case .noOriginAddress: return "Не удалось определить локальный адрес SSH-соединения."
        case .noLocalPort: return "Не удалось открыть локальный порт панели."
        case .invalidChannel: return "Промежуточный сервер отклонил SSH-переадресацию."
        case .connectionClosed: return "SSH-соединение панели закрыто."
        case .connectionTimedOut: return "Время SSH-подключения к панели истекло. Проверьте доступность сервера и учётные данные."
        case .webPolicy: return "Не удалось включить защиту локальной Web-панели."
        case .panelLocation: return "Не удалось подтвердить путь панели на сервере. Повторите подключение."
        }
    }
}

/// Relays one local TCP stream to one SSH direct-tcpip channel, including backpressure.
private final class ForwardPipe: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private weak var peer: ForwardPipe?
    private var context: ChannelHandlerContext?
    private var waitingToRead = false

    static func pair() -> (ForwardPipe, ForwardPipe) {
        let local = ForwardPipe()
        let remote = ForwardPipe()
        local.peer = remote
        remote.peer = local
        return (local, remote)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { peer?.resumeRead() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.peer = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer?.context?.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        peer?.context?.flush()
    }

    func read(context: ChannelHandlerContext) {
        if peer?.context?.channel.isWritable == true {
            context.read()
        } else {
            waitingToRead = true
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { peer?.resumeRead() }
    }

    private func resumeRead() {
        if waitingToRead {
            waitingToRead = false
            context?.read()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.context?.close(promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            peer?.context?.close(mode: .output, promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer?.context?.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class PanelSSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let failure: (Error) -> Void
    init(failure: @escaping (Error) -> Void) { self.failure = failure }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failure(error)
        context.close(promise: nil)
    }
}

/// Collects only stdout from the fixed first-login command. Stderr is ignored:
/// remote diagnostics could include arbitrary, potentially sensitive text.
private final class BootstrapPasswordExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var stdout: [UInt8] = []
    private var accepted = false
    private var exitStatus: Int?
    private var invalid = false
    private var completed = false
    private let completion: (String?) -> Void

    init(completion: @escaping (String?) -> Void) { self.completion = completion }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type,
              case .byteBuffer(let buffer) = message.data else { return }
        let count = buffer.readableBytes
        guard count <= BootstrapPassword.maximumOutputBytes - stdout.count else {
            invalid = true
            stdout.removeAll(keepingCapacity: false)
            context.close(promise: nil)
            return
        }
        stdout.append(contentsOf: buffer.readableBytesView)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            accepted = true
        case is ChannelFailureEvent:
            invalid = true
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        invalid = true
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { finish() }

    private func finish() {
        guard !completed else { return }
        completed = true
        let password = !invalid && accepted && exitStatus == 0
            ? BootstrapPassword.parse(stdout) : nil
        stdout.removeAll(keepingCapacity: false)
        completion(password)
    }
}

/// A malformed or interrupted inventory is unknown; it never authorizes first install.
private final class ServerDeploymentExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var stdout: [UInt8] = []
    private var accepted = false
    private var exitStatus: Int?
    private var invalid = false
    private var completed = false
    private let completion: (ServerDeployment) -> Void

    init(completion: @escaping (ServerDeployment) -> Void) { self.completion = completion }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type,
              case .byteBuffer(let buffer) = message.data else { return }
        guard buffer.readableBytes <= ServerDeployment.maximumOutputBytes - stdout.count else {
            invalid = true
            stdout.removeAll(keepingCapacity: false)
            context.close(promise: nil)
            return
        }
        stdout.append(contentsOf: buffer.readableBytesView)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent: accepted = true
        case is ChannelFailureEvent:
            invalid = true
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus: exitStatus = status.exitStatus
        default: context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        invalid = true
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { finish() }

    private func finish() {
        guard !completed else { return }
        completed = true
        let value = !invalid && accepted
            ? ServerDeployment.parse(stdout, exitStatus: exitStatus) : .unknown
        stdout.removeAll(keepingCapacity: false)
        completion(value)
    }
}

/// Bounded stdout collector for the fixed detached-install start/status commands.
private final class FirstInstallExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var stdout: [UInt8] = []
    private var accepted = false
    private var exitStatus: Int?
    private var invalid = false
    private var completed = false
    private let maximumBytes: Int
    private let completion: ([UInt8], Int?) -> Void

    init(maximumBytes: Int, completion: @escaping ([UInt8], Int?) -> Void) {
        self.maximumBytes = maximumBytes
        self.completion = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type,
              case .byteBuffer(let buffer) = message.data else { return }
        guard buffer.readableBytes <= maximumBytes - stdout.count else {
            invalid = true
            context.close(promise: nil)
            return
        }
        stdout.append(contentsOf: buffer.readableBytesView)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent: accepted = true
        case is ChannelFailureEvent:
            invalid = true
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus: exitStatus = status.exitStatus
        default: context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        invalid = true
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { finish() }

    private func finish() {
        guard !completed else { return }
        completed = true
        let result = invalid || !accepted ? [] : stdout
        let status = invalid || !accepted ? nil : exitStatus
        stdout.removeAll(keepingCapacity: false)
        completion(result, status)
    }
}

/// The one-shot grant is never written to a URL, log, or persistent model.
private final class SSHGrantExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var stdout: [UInt8] = []
    private var accepted = false
    private var exitStatus: Int?
    private var invalid = false
    private var completed = false
    private let completion: (String?) -> Void

    init(completion: @escaping (String?) -> Void) { self.completion = completion }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type,
              case .byteBuffer(let buffer) = message.data else { return }
        guard buffer.readableBytes <= SSHGrantResponse.maximumOutputBytes - stdout.count else {
            invalid = true
            stdout.removeAll(keepingCapacity: false)
            context.close(promise: nil)
            return
        }
        stdout.append(contentsOf: buffer.readableBytesView)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent: accepted = true
        case is ChannelFailureEvent:
            invalid = true
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus: exitStatus = status.exitStatus
        default: context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        invalid = true
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { finish() }

    private func finish() {
        guard !completed else { return }
        completed = true
        let value = !invalid && accepted
            ? SSHGrantResponse.parse(stdout, exitStatus: exitStatus) : nil
        stdout.removeAll(keepingCapacity: false)
        completion(value)
    }
}

@MainActor
final class PanelTunnel: ObservableObject {
    @Published private(set) var status = "Отключено"
    @Published private(set) var localURL: URL?
    @Published var errorMessage: String?
    @Published var hostChallenge: HostKeyChallenge?
    @Published private(set) var bootstrapPassword: String?
    @Published private(set) var bootstrapBusy = false
    @Published var bootstrapError: String?
    @Published var deploymentNotice: ServerDeployment?
    @Published private(set) var canInstallHub = false
    @Published private(set) var installBusy = false
    @Published private(set) var canUseSSHLogin = false
    @Published private(set) var routeRecoveryBusy = false
    @Published private(set) var routeRecoveryNeeded = false
    @Published private(set) var routeRevision = 0

    private var group: MultiThreadedEventLoopGroup?
    private var parent: Channel?
    private var nestedTransport: Channel?
    private var destinationSSH: NIOSSHHandler?
    private var destinationTransport: Channel?
    private var destinationAddress: String?
    private var listener: Channel?
    private var bootstrapChannel: Channel?
    private var deploymentChannel: Channel?
    private var deploymentPending = false
    private var installChannel: Channel?
    private var installStatusChannel: Channel?
    private var installStatusPending = false
    private var installStatusSafe = false
    private var requireManagedAfterInstall = false
    private var installLaunchPending = false
    private var installLaunchRetries = 0
    private var installOrigin: SocketAddress?
    private var installRootEligible = false
    private var nativeGrantChannel: Channel?
    private var nativeGrantPending = false
    private var nativeGrantIssued = false
    private var nativeGrantRequestID: UUID?
    private var managedForGrant = false
    private var explicitlyStopped = false
    private var connectionID: UUID?
    private var routeRefreshID: UUID?
    private var routeRefreshExpected: URL?

    func start(via profile: SSHServer, endpoint: PanelEndpoint) {
        guard group == nil else { return }
        let connectionID = UUID()
        self.connectionID = connectionID
        explicitlyStopped = false
        errorMessage = nil
        localURL = nil
        clearBootstrapPassword()
        bootstrapError = nil
        deploymentNotice = nil
        canInstallHub = false
        installBusy = false
        installOrigin = nil
        installStatusSafe = false
        requireManagedAfterInstall = false
        installLaunchPending = false
        installLaunchRetries = 0
        managedForGrant = false
        canUseSSHLogin = false
        nativeGrantIssued = false
        nativeGrantRequestID = nil
        routeRecoveryBusy = false
        routeRecoveryNeeded = false
        routeRevision = 0
        routeRefreshID = nil
        routeRefreshExpected = nil
        status = "Подключение по SSH…"
        destinationAddress = endpoint.address(for: profile)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.connectionID == connectionID, self.localURL == nil,
                  self.listener == nil,
                  !self.installBusy, !self.canInstallHub else { return }
            self.fail(PanelTunnelError.connectionTimedOut, for: connectionID)
        }

        let entryID = profile.jump?.id ?? profile.id
        let entryHost = profile.jump?.host ?? profile.host
        let entryPort = profile.jump?.port ?? profile.port
        let entryUsername = profile.jump?.username ?? profile.username
        installRootEligible = (endpoint.usesNestedSSH(for: profile) ? profile.username : entryUsername) == "root"
        let entryAuthKind = profile.jump?.auth ?? profile.auth
        let entryCredentials: ClientAuthDelegate
        let targetCredentials: ClientAuthDelegate?
        do {
            entryCredentials = try makeAuth(id: entryID, username: entryUsername, kind: entryAuthKind)
            targetCredentials = endpoint.usesNestedSSH(for: profile)
                ? try makeAuth(id: profile.id, username: profile.username, kind: profile.auth) : nil
        } catch {
            fail(error, for: connectionID)
            return
        }
        let askHost: (String, String, @escaping (Bool) -> Void) -> Void = { [weak self] address, fingerprint, answer in
            DispatchQueue.main.async {
                guard let self, self.connectionID == connectionID else {
                    answer(false)
                    return
                }
                self.hostChallenge = HostKeyChallenge(fingerprint: fingerprint, address: address, resolve: answer)
            }
        }
        let entryHostAuth = HostKeyDelegate(id: entryID, address: "\(entryHost):\(entryPort)", challenge: askHost)
        let targetHostAuth = endpoint.usesNestedSSH(for: profile)
            ? HostKeyDelegate(id: profile.id, address: "\(profile.host):\(profile.port)", challenge: askHost) : nil
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = eventLoopGroup
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: entryCredentials, serverAuthDelegate: entryHostAuth)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(PanelSSHErrorHandler { error in
                        DispatchQueue.main.async { self?.fail(error, for: connectionID) }
                    })
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        bootstrap.connect(host: entryHost, port: entryPort).whenComplete { [weak self] result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self?.fail(error, for: connectionID) }
            case .success(let channel):
                DispatchQueue.main.async {
                    guard let self, self.connectionID == connectionID,
                          let activeGroup = self.group, activeGroup === eventLoopGroup else {
                        channel.close(promise: nil)
                        return
                    }
                    self.parent = channel
                    self.observeTransport(channel, for: connectionID)
                    self.prepareDestination(entry: channel, profile: profile, endpoint: endpoint,
                                            targetCredentials: targetCredentials, targetHostAuth: targetHostAuth,
                                            group: eventLoopGroup, connectionID: connectionID)
                }
            }
        }
    }

    private func observeTransport(_ channel: Channel, for connectionID: UUID) {
        channel.closeFuture.whenComplete { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.connectionID == connectionID else { return }
                self.fail(PanelTunnelError.connectionClosed, for: connectionID)
            }
        }
    }

    private func prepareDestination(entry: Channel, profile: SSHServer, endpoint: PanelEndpoint,
                                    targetCredentials: ClientAuthDelegate?, targetHostAuth: HostKeyDelegate?,
                                    group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        guard let origin = entry.localAddress else {
            fail(PanelTunnelError.noOriginAddress, for: connectionID)
            return
        }
        entry.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] handlerResult in
            DispatchQueue.main.async {
                guard let self, self.connectionID == connectionID else { return }
                switch handlerResult {
                case .failure(let error): self.fail(error, for: connectionID)
                case .success(let entrySSH):
                    guard endpoint.usesNestedSSH(for: profile) else {
                        self.probePanel(using: entrySSH, transport: entry, origin: origin,
                                        group: eventLoopGroup, connectionID: connectionID)
                        return
                    }
                    guard let targetCredentials, let targetHostAuth else {
                        self.fail(PanelTunnelError.invalidChannel, for: connectionID)
                        return
                    }
                    self.openNestedDestination(entrySSH: entrySSH, entry: entry, origin: origin,
                                               profile: profile, targetCredentials: targetCredentials,
                                               targetHostAuth: targetHostAuth, group: eventLoopGroup,
                                               connectionID: connectionID)
                }
            }
        }
    }

    private func openNestedDestination(entrySSH: NIOSSHHandler, entry: Channel, origin: SocketAddress,
                                       profile: SSHServer, targetCredentials: ClientAuthDelegate,
                                       targetHostAuth: HostKeyDelegate,
                                       group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        let direct = SSHChannelType.DirectTCPIP(
            targetHost: profile.host, targetPort: profile.port, originatorAddress: origin)
        let promise = entry.eventLoop.makePromise(of: Channel.self)
        entry.eventLoop.execute {
            guard entry.isActive else {
                promise.fail(PanelTunnelError.connectionClosed)
                return
            }
            entrySSH.createChannel(promise, channelType: .directTCPIP(direct)) { [weak self] tunnel, type in
                guard case .directTCPIP = type else {
                    return tunnel.eventLoop.makeFailedFuture(PanelTunnelError.invalidChannel)
                }
                return tunnel.eventLoop.makeCompletedFuture {
                    let nested = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: targetCredentials, serverAuthDelegate: targetHostAuth)),
                        allocator: tunnel.allocator, inboundChildChannelInitializer: nil)
                    try tunnel.pipeline.syncOperations.addHandler(SSHStreamWrapper())
                    try tunnel.pipeline.syncOperations.addHandler(nested)
                    try tunnel.pipeline.syncOperations.addHandler(PanelSSHErrorHandler { error in
                        DispatchQueue.main.async { self?.fail(error, for: connectionID) }
                    })
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.connectionID == connectionID else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                switch result {
                case .failure(let error): self.fail(error, for: connectionID)
                case .success(let tunnel):
                    self.nestedTransport = tunnel
                    self.observeTransport(tunnel, for: connectionID)
                    tunnel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] nestedResult in
                        DispatchQueue.main.async {
                            guard let self, self.connectionID == connectionID else { return }
                            switch nestedResult {
                            case .failure(let error): self.fail(error, for: connectionID)
                            case .success(let nestedSSH):
                                self.probePanel(using: nestedSSH, transport: tunnel, origin: origin,
                                                group: eventLoopGroup, connectionID: connectionID)
                            }
                        }
                    }
                }
            }
        }
    }

    private func probePanel(using ssh: NIOSSHHandler, transport: Channel, origin: SocketAddress,
                            group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        guard self.connectionID == connectionID, !installStatusPending else { return }
        destinationSSH = ssh
        destinationTransport = transport
        installStatusPending = true
        let promise = transport.eventLoop.makePromise(of: Channel.self)
        transport.eventLoop.execute {
            guard transport.isActive else {
                promise.fail(PanelTunnelError.connectionClosed)
                return
            }
            ssh.createChannel(promise) { [weak self] child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(PanelTunnelError.invalidChannel)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(FirstInstallExecHandler(
                        maximumBytes: SovaGridFirstInstall.maximumOutputBytes) { [weak self] bytes, exitStatus in
                        let job = SovaGridFirstInstall.parseStatus(bytes, exitStatus: exitStatus)
                        DispatchQueue.main.async {
                            self?.finishInstallStatus(job, using: ssh, transport: transport, origin: origin,
                                                      group: eventLoopGroup, connectionID: connectionID)
                        }
                    })
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self?.finishInstallStatus(FirstInstallJob(.unknown), using: ssh, transport: transport,
                                              origin: origin, group: eventLoopGroup, connectionID: connectionID)
                }
            case .success(let child):
                DispatchQueue.main.async {
                    guard let self, self.connectionID == connectionID, self.installStatusPending else {
                        child.close(promise: nil)
                        return
                    }
                    self.installStatusChannel = child
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self, self.connectionID == connectionID,
                              self.installStatusPending, self.installStatusChannel === child else { return }
                        self.finishInstallStatus(FirstInstallJob(.unknown), using: ssh, transport: transport,
                                                 origin: origin, group: eventLoopGroup, connectionID: connectionID)
                        child.close(promise: nil)
                    }
                }
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(
                    command: SovaGridFirstInstall.statusCommand, wantReply: true
                )).whenFailure { _ in child.close(promise: nil) }
            }
        }
    }

    private func finishInstallStatus(_ job: FirstInstallJob, using ssh: NIOSSHHandler,
                                     transport: Channel, origin: SocketAddress,
                                     group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        guard self.connectionID == connectionID, installStatusPending else { return }
        installStatusPending = false
        installStatusChannel = nil
        switch job.state {
        case .running:
            installBusy = true
            installLaunchPending = false
            canInstallHub = false
            status = SovaGridFirstInstall.stageText(job.stage)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.connectionID == connectionID else { return }
                self.probePanel(using: ssh, transport: transport, origin: origin,
                                group: eventLoopGroup, connectionID: connectionID)
            }
        case .done:
            installBusy = false
            installLaunchPending = false
            installStatusSafe = false
            requireManagedAfterInstall = true
            status = "Установка завершена; подтверждаем Hub…"
            probeDeployment(using: ssh, transport: transport, origin: origin,
                            group: eventLoopGroup, connectionID: connectionID)
        case .failed:
            errorMessage = SovaGridFirstInstall.failureText(job.reason)
            stop()
            status = "Установка на сервере требует проверки"
        case .none:
            if installLaunchPending && installLaunchRetries < 5 {
                installLaunchRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.connectionID == connectionID else { return }
                    self.probePanel(using: ssh, transport: transport, origin: origin,
                                    group: eventLoopGroup, connectionID: connectionID)
                }
                return
            }
            if installLaunchPending {
                errorMessage = "Сервер не подтвердил запуск установки. Проверьте его состояние."
                stop()
                return
            }
            installStatusSafe = true
            probeDeployment(using: ssh, transport: transport, origin: origin,
                            group: eventLoopGroup, connectionID: connectionID)
        case .unknown:
            if installLaunchPending || installBusy {
                errorMessage = "Состояние установки недоступно. Проверьте сервер перед повторением."
                stop()
            } else {
                installStatusSafe = false
                probeDeployment(using: ssh, transport: transport, origin: origin,
                                group: eventLoopGroup, connectionID: connectionID)
            }
        }
    }

    private func probeDeployment(using ssh: NIOSSHHandler, transport: Channel, origin: SocketAddress,
                                 group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        guard self.connectionID == connectionID else { return }
        destinationSSH = ssh
        destinationTransport = transport
        deploymentPending = true
        status = "Проверяем SovaGrid на сервере…"
        let promise = transport.eventLoop.makePromise(of: Channel.self)
        transport.eventLoop.execute { [weak self] in
            guard transport.isActive else {
                promise.fail(PanelTunnelError.connectionClosed)
                return
            }
            ssh.createChannel(promise) { [weak self] child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(PanelTunnelError.invalidChannel)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(ServerDeploymentExecHandler { [weak self] state in
                        DispatchQueue.main.async {
                            self?.finishDeployment(state, using: ssh, transport: transport, origin: origin,
                                                   group: eventLoopGroup, connectionID: connectionID)
                        }
                    })
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self?.finishDeployment(.unknown, using: ssh, transport: transport, origin: origin,
                                           group: eventLoopGroup, connectionID: connectionID)
                }
            case .success(let child):
                DispatchQueue.main.async {
                    guard let self, self.connectionID == connectionID, self.deploymentPending else {
                        child.close(promise: nil)
                        return
                    }
                    self.deploymentChannel = child
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self, self.connectionID == connectionID,
                              self.deploymentPending, self.deploymentChannel === child else { return }
                        self.finishDeployment(.unknown, using: ssh, transport: transport, origin: origin,
                                              group: eventLoopGroup, connectionID: connectionID)
                        child.close(promise: nil)
                    }
                }
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(
                    command: ServerDeploymentProbe.command, wantReply: true
                )).whenFailure { _ in child.close(promise: nil) }
            }
        }
    }

    private func finishDeployment(_ state: ServerDeployment, using ssh: NIOSSHHandler,
                                  transport: Channel, origin: SocketAddress,
                                  group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        guard self.connectionID == connectionID, deploymentPending else { return }
        deploymentPending = false
        deploymentChannel = nil
        switch state {
        case .managed:
            requireManagedAfterInstall = false
            managedForGrant = true
            canUseSSHLogin = true
            probePanelPort(using: ssh, transport: transport, origin: origin,
                           group: eventLoopGroup, connectionID: connectionID)
        case .unknown:
            if requireManagedAfterInstall {
                errorMessage = "Установка завершилась, но управляемый Hub не подтверждён. Проверьте сервер."
                stop()
                status = "Установка требует проверки"
                return
            }
            managedForGrant = false
            canUseSSHLogin = false
            probePanelPort(using: ssh, transport: transport, origin: origin,
                           group: eventLoopGroup, connectionID: connectionID)
        case .missing where installRootEligible && installStatusSafe:
            installOrigin = origin
            canInstallHub = true
            deploymentNotice = .missing
            status = "SovaGrid не установлен: можно установить по SSH"
        case .missing, .agentOnly, .conflict, .unsupported:
            stop()
            deploymentNotice = state
            status = "Панель на этом узле недоступна"
        }
    }

    /// Starts one detached systemd job after explicit confirmation. SSH loss only stops observation.
    func installHub() {
        guard canInstallHub, installRootEligible, installStatusSafe, !installBusy,
              let destinationSSH, let destinationTransport, let installOrigin,
              let connectionID, let eventLoopGroup = group else { return }
        canInstallHub = false
        installBusy = true
        installLaunchPending = true
        installLaunchRetries = 0
        status = "Запускаем установку на сервере…"
        let promise = destinationTransport.eventLoop.makePromise(of: Channel.self)
        destinationTransport.eventLoop.execute {
            guard destinationTransport.isActive else {
                promise.fail(PanelTunnelError.connectionClosed)
                return
            }
            destinationSSH.createChannel(promise) { [weak self] child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(PanelTunnelError.invalidChannel)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(FirstInstallExecHandler(maximumBytes: 64) {
                        [weak self] bytes, exitStatus in
                        let accepted = SovaGridFirstInstall.startAccepted(bytes, exitStatus: exitStatus)
                        DispatchQueue.main.async {
                            self?.finishInstallStart(accepted, using: destinationSSH,
                                                     transport: destinationTransport, origin: installOrigin,
                                                     group: eventLoopGroup, connectionID: connectionID)
                        }
                    })
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self?.finishInstallStart(false, using: destinationSSH,
                                             transport: destinationTransport, origin: installOrigin,
                                             group: eventLoopGroup, connectionID: connectionID)
                }
            case .success(let child):
                DispatchQueue.main.async {
                    guard let self, self.connectionID == connectionID, self.installLaunchPending else {
                        child.close(promise: nil)
                        return
                    }
                    self.installChannel = child
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                        guard let self, self.connectionID == connectionID,
                              self.installLaunchPending, self.installChannel === child else { return }
                        self.finishInstallStart(false, using: destinationSSH,
                                                transport: destinationTransport, origin: installOrigin,
                                                group: eventLoopGroup, connectionID: connectionID)
                        child.close(promise: nil)
                    }
                }
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(
                    command: SovaGridFirstInstall.startCommand, wantReply: true
                )).whenFailure { _ in child.close(promise: nil) }
            }
        }
    }

    private func finishInstallStart(_ accepted: Bool, using ssh: NIOSSHHandler,
                                    transport: Channel, origin: SocketAddress,
                                    group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        guard self.connectionID == connectionID, installLaunchPending else { return }
        installChannel = nil
        status = accepted ? "Задание запущено; читаем состояние…" : "Проверяем, запустилось ли задание…"
        probePanel(using: ssh, transport: transport, origin: origin,
                   group: eventLoopGroup, connectionID: connectionID)
    }

    private func probePanelPort(using ssh: NIOSSHHandler, transport: Channel, origin: SocketAddress,
                                group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        guard self.connectionID == connectionID else { return }
        // A successful probe proves both SSH authentication and access to the fixed panel port.
        let probe = transport.eventLoop.makePromise(of: Channel.self)
        let destination = SSHChannelType.DirectTCPIP(
            targetHost: "127.0.0.1", targetPort: 8766, originatorAddress: origin)
        transport.eventLoop.execute {
            guard transport.isActive else {
                probe.fail(PanelTunnelError.connectionClosed)
                return
            }
            ssh.createChannel(probe, channelType: .directTCPIP(destination)) { child, type in
                guard case .directTCPIP = type else {
                    return child.eventLoop.makeFailedFuture(PanelTunnelError.invalidChannel)
                }
                return child.eventLoop.makeSucceededFuture(())
            }
        }
        probe.futureResult.whenComplete { [weak self] probeResult in
            switch probeResult {
            case .failure(let error):
                DispatchQueue.main.async { self?.fail(error, for: connectionID) }
            case .success(let child):
                child.close(promise: nil)
                DispatchQueue.main.async {
                    guard let self, self.connectionID == connectionID,
                          let destinationSSH = self.destinationSSH else { return }
                    self.startListener(using: destinationSSH, origin: origin, group: eventLoopGroup,
                                       connectionID: connectionID)
                }
            }
        }
    }

    func acceptHostKey(_ accepted: Bool) {
        let challenge = hostChallenge
        hostChallenge = nil
        challenge?.resolve(accepted)
    }

    func fetchBootstrapPassword() {
        guard localURL != nil, let destinationSSH, let destinationTransport,
              let connectionID, !bootstrapBusy else { return }
        clearBootstrapPassword()
        bootstrapError = nil
        bootstrapBusy = true
        let promise = destinationTransport.eventLoop.makePromise(of: Channel.self)
        destinationTransport.eventLoop.execute { [weak self] in
            guard destinationTransport.isActive else {
                promise.fail(PanelTunnelError.connectionClosed)
                return
            }
            destinationSSH.createChannel(promise) { [weak self] child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(PanelTunnelError.invalidChannel)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(BootstrapPasswordExecHandler { [weak self] password in
                        DispatchQueue.main.async { self?.finishBootstrap(password, for: connectionID) }
                    })
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure:
                DispatchQueue.main.async { self?.finishBootstrap(nil, for: connectionID) }
            case .success(let child):
                DispatchQueue.main.async {
                    guard let self, self.connectionID == connectionID, self.bootstrapBusy else {
                        child.close(promise: nil)
                        return
                    }
                    self.bootstrapChannel = child
                    // A server that never completes the command must not hold the UI indefinitely.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self, self.connectionID == connectionID,
                              self.bootstrapBusy, self.bootstrapChannel === child else { return }
                        self.finishBootstrap(nil, for: connectionID)
                        child.close(promise: nil)
                    }
                }
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(
                    command: BootstrapPassword.command, wantReply: true
                )).whenFailure { _ in child.close(promise: nil) }
            }
        }
    }

    func clearBootstrapPassword() { bootstrapPassword = nil }

    /// Called once after the trusted loopback page has finished loading.
    func fetchNativeSSHGrant(retry: Bool = false, _ completion: @escaping (String?) -> Void) {
        if retry && !nativeGrantPending { nativeGrantIssued = false }
        guard managedForGrant, !routeRecoveryBusy, !routeRecoveryNeeded,
              !nativeGrantIssued, !nativeGrantPending,
              localURL != nil, let destinationSSH, let destinationTransport,
              let connectionID else {
            completion(nil)
            return
        }
        nativeGrantIssued = true
        nativeGrantPending = true
        let requestID = UUID()
        nativeGrantRequestID = requestID
        let promise = destinationTransport.eventLoop.makePromise(of: Channel.self)
        destinationTransport.eventLoop.execute { [weak self] in
            guard destinationTransport.isActive else {
                promise.fail(PanelTunnelError.connectionClosed)
                return
            }
            destinationSSH.createChannel(promise) { [weak self] child, type in
                guard type == .session else {
                    return child.eventLoop.makeFailedFuture(PanelTunnelError.invalidChannel)
                }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SSHGrantExecHandler { [weak self] grant in
                        DispatchQueue.main.async {
                            self?.finishNativeSSHGrant(grant, for: connectionID, requestID: requestID,
                                                       completion: completion)
                        }
                    })
                }
            }
        }
        promise.futureResult.whenComplete { [weak self] result in
            switch result {
            case .failure:
                DispatchQueue.main.async {
                    self?.finishNativeSSHGrant(nil, for: connectionID, requestID: requestID,
                                               completion: completion)
                }
            case .success(let child):
                DispatchQueue.main.async {
                    guard let self, self.connectionID == connectionID,
                          self.nativeGrantPending, self.nativeGrantRequestID == requestID else {
                        child.close(promise: nil)
                        return
                    }
                    self.nativeGrantChannel = child
                    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                        guard let self, self.connectionID == connectionID,
                              self.nativeGrantPending, self.nativeGrantRequestID == requestID,
                              self.nativeGrantChannel === child else { return }
                        self.finishNativeSSHGrant(nil, for: connectionID, requestID: requestID,
                                                  completion: completion)
                        child.close(promise: nil)
                    }
                }
                child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(
                    command: SSHGrantResponse.command, wantReply: true
                )).whenFailure { _ in child.close(promise: nil) }
            }
        }
    }

    private func finishNativeSSHGrant(_ grant: String?, for connectionID: UUID, requestID: UUID,
                                      completion: @escaping (String?) -> Void) {
        guard self.connectionID == connectionID, nativeGrantPending,
              nativeGrantRequestID == requestID else { return }
        nativeGrantPending = false
        nativeGrantChannel = nil
        nativeGrantRequestID = nil
        completion(grant)
    }

    private func finishBootstrap(_ password: String?, for connectionID: UUID) {
        guard self.connectionID == connectionID, bootstrapBusy else { return }
        bootstrapBusy = false
        bootstrapChannel = nil
        if let password {
            bootstrapPassword = password
        } else {
            bootstrapError = "Не удалось прочитать начальный пароль. SSH-пользователю нужен доступ к /etc/sovagrid/admin-password."
        }
    }

    func stop() {
        explicitlyStopped = true
        if hostChallenge != nil { acceptHostKey(false) }
        connectionID = nil
        localURL = nil
        clearBootstrapPassword()
        bootstrapBusy = false
        bootstrapError = nil
        status = "Отключено"
        let oldListener = listener
        let oldParent = parent
        let oldNestedTransport = nestedTransport
        let oldBootstrapChannel = bootstrapChannel
        let oldDeploymentChannel = deploymentChannel
        let oldInstallChannel = installChannel
        let oldInstallStatusChannel = installStatusChannel
        let oldNativeGrantChannel = nativeGrantChannel
        let oldGroup = group
        listener = nil
        parent = nil
        nestedTransport = nil
        destinationSSH = nil
        destinationTransport = nil
        destinationAddress = nil
        bootstrapChannel = nil
        deploymentChannel = nil
        deploymentPending = false
        installChannel = nil
        installStatusChannel = nil
        installStatusPending = false
        installStatusSafe = false
        requireManagedAfterInstall = false
        installLaunchPending = false
        installLaunchRetries = 0
        installOrigin = nil
        installRootEligible = false
        canInstallHub = false
        installBusy = false
        nativeGrantChannel = nil
        nativeGrantPending = false
        nativeGrantIssued = false
        nativeGrantRequestID = nil
        routeRecoveryBusy = false
        routeRecoveryNeeded = false
        routeRevision = 0
        routeRefreshID = nil
        routeRefreshExpected = nil
        managedForGrant = false
        canUseSSHLogin = false
        group = nil
        let closeFutures = [oldListener, oldBootstrapChannel, oldDeploymentChannel,
                            oldInstallChannel, oldInstallStatusChannel,
                            oldNativeGrantChannel, oldNestedTransport, oldParent]
            .compactMap { $0?.close() }
        if let oldGroup {
            EventLoopFuture.whenAllComplete(closeFutures, on: oldGroup.next()).whenComplete { _ in
                DispatchQueue.global(qos: .utility).async { try? oldGroup.syncShutdownGracefully() }
            }
        }
    }

    func webPolicyFailed(for url: URL) {
        guard localURL == url, let connectionID else { return }
        fail(PanelTunnelError.webPolicy, for: connectionID)
    }

    private func startListener(using ssh: NIOSSHHandler, origin: SocketAddress,
                               group eventLoopGroup: MultiThreadedEventLoopGroup, connectionID: UUID) {
        guard self.connectionID == connectionID,
              let activeGroup = group, activeGroup === eventLoopGroup else { return }
        let listenerBootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { [weak self] local in
                let direct = SSHChannelType.DirectTCPIP(
                    targetHost: "127.0.0.1", targetPort: 8766,
                    originatorAddress: local.remoteAddress ?? origin)
                let promise = local.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(promise, channelType: .directTCPIP(direct)) { remote, type in
                    guard case .directTCPIP = type else {
                        return remote.eventLoop.makeFailedFuture(PanelTunnelError.invalidChannel)
                    }
                    return remote.eventLoop.makeCompletedFuture {
                        let (localPipe, remotePipe) = ForwardPipe.pair()
                        try remote.pipeline.syncOperations.addHandler(SSHStreamWrapper())
                        try remote.pipeline.syncOperations.addHandler(remotePipe)
                        try local.pipeline.syncOperations.addHandler(localPipe)
                    }
                }
                promise.futureResult.whenFailure { error in
                    local.close(promise: nil)
                    DispatchQueue.main.async {
                        guard self?.connectionID == connectionID else { return }
                        self?.errorMessage = error.localizedDescription
                    }
                }
                return promise.futureResult.map { _ in }
            }
        listenerBootstrap.bind(host: "127.0.0.1", port: 0).whenComplete { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.connectionID == connectionID,
                      let activeGroup = self.group, activeGroup === eventLoopGroup else { return }
                switch result {
                case .failure(let error):
                    self.fail(error, for: connectionID)
                case .success(let listener):
                    guard let localPort = listener.localAddress?.port else {
                        listener.close(promise: nil)
                        self.fail(PanelTunnelError.noLocalPort, for: connectionID)
                        return
                    }
                    self.listener = listener
                    self.status = "Определяем путь панели через SSH…"
                    Task { [weak self] in
                        await self?.discoverPanelURL(port: localPort, connectionID: connectionID)
                    }
                }
            }
        }
    }

    /// A Web navigation is only a hint. Re-read the active path through this SSH
    /// tunnel and verify its page and manifest before granting it native access.
    func refreshPanelRoute(navigatedTo candidate: URL, stillCurrent: @escaping () -> Bool) {
        guard let previous = localURL, let port = previous.port,
              let connectionID, listener != nil else { return }
        let origin = "http://127.0.0.1:\(port)"
        guard candidate != previous, Self.validPanelPath(candidate.path),
              candidate.absoluteString == origin + candidate.path else { return }
        beginRouteRefresh(previous: previous, port: port, connectionID: connectionID,
                          expected: candidate, stillCurrent: stillCurrent)
    }

    /// Used after an HTTP error and by the visible retry button. The advertised
    /// path may have changed, so no path supplied by the failed page is trusted.
    func recoverPanelRoute() {
        guard let previous = localURL, let port = previous.port,
              let connectionID, listener != nil else { return }
        beginRouteRefresh(previous: previous, port: port, connectionID: connectionID,
                          expected: nil, stillCurrent: { true })
    }

    private func beginRouteRefresh(previous: URL, port: Int, connectionID: UUID,
                                   expected: URL?, stillCurrent: @escaping () -> Bool) {
        if routeRecoveryBusy && routeRefreshExpected == expected { return }
        let refreshID = UUID()
        routeRefreshID = refreshID
        routeRefreshExpected = expected
        routeRecoveryBusy = true
        routeRecoveryNeeded = false
        status = "Проверяем путь панели через SSH…"
        // No one-use grant may reach a document while its route is in question.
        invalidateNativeGrant()
        Task { [weak self] in
            guard let self else { return }
            let verified = await self.resolvePanelURL(port: port, connectionID: connectionID,
                                                      expected: expected)
            guard self.connectionID == connectionID, self.localURL == previous,
                  self.listener != nil, self.routeRefreshID == refreshID else { return }
            self.routeRefreshID = nil
            self.routeRefreshExpected = nil
            self.routeRecoveryBusy = false
            guard let verified, stillCurrent() else {
                self.routeRecoveryNeeded = true
                self.status = "Путь панели пока недоступен"
                return
            }
            self.routeRecoveryNeeded = false
            if verified == previous { self.routeRevision += 1 }
            else { self.localURL = verified }
            self.status = "Панель через SSH: \(self.destinationAddress ?? "сервер")"
        }
    }

    private func invalidateNativeGrant() {
        let oldGrant = nativeGrantChannel
        nativeGrantRequestID = nil
        nativeGrantChannel = nil
        nativeGrantPending = false
        nativeGrantIssued = false
        oldGrant?.close(promise: nil)
    }

    private func discoverPanelURL(port: Int, connectionID: UUID) async {
        guard let verified = await resolvePanelURL(port: port, connectionID: connectionID) else {
            fail(PanelTunnelError.panelLocation, for: connectionID)
            return
        }
        guard self.connectionID == connectionID, listener != nil else { return }
        self.localURL = verified
        self.status = "Панель через SSH: \(self.destinationAddress ?? "сервер")"
    }

    private func resolvePanelURL(port: Int, connectionID: UUID,
                                 expected: URL? = nil) async -> URL? {
        let origin = "http://127.0.0.1:\(port)"
        guard let locationURL = URL(string: origin + "/api/v1/panel-location") else {
            return nil
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            guard self.connectionID == connectionID, listener != nil else { return nil }
            var paths: [String] = []
            do {
                var request = URLRequest(url: locationURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 1
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.url == locationURL else {
                    return nil
                }
                if http.statusCode == 404 {
                    paths = ["/sovagrid/monitoring/", "/"]
                }
                if http.statusCode == 503 { /* Broker is still loading its route. */ }
                else if http.statusCode == 200, data.count <= 512,
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        object.count == 1, let path = object["panel_path"] as? String,
                        Self.validPanelPath(path) {
                    paths = [path]
                } else if http.statusCode != 404 {
                    return nil
                }
            } catch {
                // The SSH listener may become ready slightly before Hub.
            }
            for path in paths {
                guard let url = URL(string: origin + path),
                      expected == nil || expected == url,
                      await verifiedPanelPage(url) else { continue }
                guard self.connectionID == connectionID, listener != nil else { return nil }
                return url
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    private static func validPanelPath(_ path: String) -> Bool {
        guard path.utf8.count <= 96,
              path.range(of: #"^/(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/){1,3}$"#,
                         options: .regularExpression) != nil else { return false }
        return !["api", "healthz"].contains(path.split(separator: "/").first.map(String.init) ?? "")
    }

    private func verifiedPanelPage(_ url: URL) async -> Bool {
        guard let manifest = URL(string: "manifest.webmanifest", relativeTo: url)?.absoluteURL else {
            return false
        }
        for (target, mime, limit) in [(url, "text/html", 262_144),
                                      (manifest, "application/manifest+json", 8_192)] {
            do {
                var request = URLRequest(url: target)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 2
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.url == target,
                      http.statusCode == 200, data.count <= limit,
                      (http.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix(mime) else {
                    return false
                }
                if target == url && data.range(of: Data("SovaGrid".utf8)) == nil { return false }
                if target == manifest {
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let name = object["name"] as? String, name.contains("SovaGrid") else {
                        return false
                    }
                }
            } catch { return false }
        }
        return true
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

    private func fail(_ error: Error, for connectionID: UUID) {
        guard !explicitlyStopped, self.connectionID == connectionID else { return }
        if errorMessage == nil { errorMessage = error.localizedDescription }
        stop()
        status = "Ошибка подключения"
    }
}
