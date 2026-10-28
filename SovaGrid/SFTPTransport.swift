// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

struct SFTPReply {
    let type: UInt8
    let payload: Data // request id has already been checked and removed
}

/// Runs on one NIO event loop. Only one request is in flight, bounding buffers
/// and making cancellation/response matching easy to audit.
final class SFTPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private var receive = ByteBufferAllocator().buffer(capacity: 0)
    private var channel: Channel?
    private var readyPromise: EventLoopPromise<Void>?
    private var pending: (id: UInt32, promise: EventLoopPromise<SFTPReply>, timeout: Scheduled<Void>)?
    private var nextID: UInt32 = 1
    private var ready = false
    private var awaitingSubsystem = false

    func start(on channel: Channel) -> EventLoopFuture<Void> {
        precondition(channel.eventLoop.inEventLoop)
        self.channel = channel
        let promise = channel.eventLoop.makePromise(of: Void.self)
        readyPromise = promise
        awaitingSubsystem = true
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true))
            .whenFailure { [weak self] error in self?.abort(error) }
        return promise.futureResult
    }

    func request(_ type: UInt8, payload: Data) -> EventLoopFuture<SFTPReply> {
        guard let channel else { preconditionFailure("SFTP channel was not started") }
        precondition(channel.eventLoop.inEventLoop)
        guard ready, pending == nil else {
            return channel.eventLoop.makeFailedFuture(SFTPWireError.unexpectedResponse)
        }
        let id = nextID
        nextID &+= 1
        let promise = channel.eventLoop.makePromise(of: SFTPReply.self)
        do {
            var writer = SFTPWire.Writer()
            writer.u32(id)
            writer.bytes(payload)
            let packet = try SFTPWire.packet(type, writer.data)
            let timeout = channel.eventLoop.scheduleTask(in: .seconds(20)) { [weak self] in
                guard let self else { return }
                self.abort(SFTPWireError.timedOut)
            }
            pending = (id, promise, timeout)
            send(packet, on: channel).whenFailure { [weak self] error in self?.abort(error) }
        } catch {
            promise.fail(error)
        }
        return promise.futureResult
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if awaitingSubsystem, event is ChannelSuccessEvent {
            awaitingSubsystem = false
            var initPacket = SFTPWire.Writer()
            initPacket.u32(3)
            do {
                send(try SFTPWire.packet(1, initPacket.data), on: context.channel)
                    .whenFailure { [weak self] error in self?.abort(error) }
            } catch { abort(error) }
        } else if awaitingSubsystem, event is ChannelFailureEvent {
            abort(SFTPWireError.unsupportedVersion)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type,
              case .byteBuffer(let buffer) = message.data else { return }
        guard receive.readableBytes + buffer.readableBytes <= SFTPWire.maximumPacketBytes + 4 else {
            abort(SFTPWireError.tooLarge)
            return
        }
        receive.writeBytes(buffer.readableBytesView)
        while receive.readableBytes >= 4 {
            guard let length: UInt32 = receive.getInteger(at: receive.readerIndex),
                  length > 0, length <= SFTPWire.maximumPacketBytes else {
                abort(SFTPWireError.tooLarge)
                return
            }
            guard receive.readableBytes >= Int(length) + 4 else { break }
            receive.moveReaderIndex(forwardBy: 4)
            guard let type: UInt8 = receive.readInteger(),
                  let bytes = receive.readBytes(length: Int(length) - 1) else {
                abort(SFTPWireError.malformed)
                return
            }
            do {
                try handle(type: type, payload: Data(bytes))
            } catch {
                abort(error)
                return
            }
        }
        receive.discardReadBytes()
    }

    private func handle(type: UInt8, payload: Data) throws {
        var reader = SFTPWire.Reader(payload)
        if !ready {
            guard type == 2, try reader.u32() == 3 else { throw SFTPWireError.unsupportedVersion }
            ready = true
            readyPromise?.succeed(())
            readyPromise = nil
            return
        }
        let id = try reader.u32()
        guard let pending, pending.id == id else { throw SFTPWireError.unexpectedResponse }
        self.pending = nil
        pending.timeout.cancel()
        pending.promise.succeed(.init(type: type, payload: try reader.bytes(reader.remaining)))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        abort(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        abort(SFTPWireError.cancelled)
        context.fireChannelInactive()
    }

    private func abort(_ error: Error) {
        readyPromise?.fail(error)
        readyPromise = nil
        if let pending {
            pending.timeout.cancel()
            pending.promise.fail(error)
            self.pending = nil
        }
        channel?.close(promise: nil)
    }

    private func send(_ packet: Data, on channel: Channel) -> EventLoopFuture<Void> {
        var buffer = channel.allocator.buffer(capacity: packet.count)
        buffer.writeBytes(packet)
        return channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }
}

enum SFTPOutcome {
    case listing([SFTPFileEntry])
    case uploaded
    case downloaded(URL)
}

enum SFTPJob {
    case list(path: String)
    case upload(local: FileHandle, size: UInt64, remotePath: String)
    case download(local: FileHandle, localURL: URL, remotePath: String)
}

/// SFTP v3 requests; every response is checked before the next request.
final class SFTPClient {
    private let wire: SFTPChannelHandler
    private let loop: EventLoop
    private let report: (UInt64, UInt64?) -> Void

    init(wire: SFTPChannelHandler, loop: EventLoop, report: @escaping (UInt64, UInt64?) -> Void) {
        self.wire = wire
        self.loop = loop
        self.report = report
    }

    func perform(_ job: SFTPJob) -> EventLoopFuture<SFTPOutcome> {
        switch job {
        case .list(let path):
            return list(path: path).map { .listing($0) }
        case .upload(let local, let size, let remotePath):
            return upload(local: local, size: size, remotePath: remotePath).map { .uploaded }
        case .download(let local, let localURL, let remotePath):
            return download(local: local, localURL: localURL, remotePath: remotePath)
                .map { .downloaded(localURL) }
        }
    }

    private func request(_ type: UInt8, _ build: (inout SFTPWire.Writer) throws -> Void) -> EventLoopFuture<SFTPReply> {
        do {
            var writer = SFTPWire.Writer()
            try build(&writer)
            return wire.request(type, payload: writer.data)
        } catch { return loop.makeFailedFuture(error) }
    }

    private func status(_ reply: SFTPReply, expected: UInt32 = 0) throws {
        guard reply.type == 101 else { throw SFTPWireError.unexpectedResponse }
        var reader = SFTPWire.Reader(reply.payload)
        let code = try reader.u32()
        guard code == expected else { throw SFTPWireError.remoteStatus(code) }
    }

    private func handle(_ reply: SFTPReply) throws -> Data {
        if reply.type == 101 { try status(reply); throw SFTPWireError.unexpectedResponse }
        guard reply.type == 102 else { throw SFTPWireError.unexpectedResponse }
        var reader = SFTPWire.Reader(reply.payload)
        let handle = try reader.string(maximum: 4_096)
        guard reader.remaining == 0 else { throw SFTPWireError.malformed }
        return handle
    }

    private func close(_ handle: Data) -> EventLoopFuture<Void> {
        request(4) { $0.string(handle) }.flatMapThrowing { try self.status($0) }
    }

    private func remove(_ path: String) -> EventLoopFuture<Void> {
        request(13) { $0.string(try SFTPWire.path(path)) }
            .flatMapThrowing { try self.status($0) }
    }

    private func closeAfter<T>(_ handle: Data, result: EventLoopFuture<T>) -> EventLoopFuture<T> {
        let wrapped: EventLoopFuture<Result<T, Error>> = result
            .map { .success($0) }
            .flatMapError { self.loop.makeSucceededFuture(.failure($0)) }
        return wrapped.flatMap { outcome in
            self.close(handle).flatMapThrowing {
                try outcome.get()
            }.flatMapError { closeError in
                switch outcome {
                case .success: return self.loop.makeFailedFuture(closeError)
                case .failure(let operationError): return self.loop.makeFailedFuture(operationError)
                }
            }
        }
    }

    private func list(path: String) -> EventLoopFuture<[SFTPFileEntry]> {
        request(11) { $0.string(try SFTPWire.path(path)) }
            .flatMapThrowing(handle)
            .flatMap { handle in
                self.closeAfter(handle, result: self.readDirectory(handle, entries: []))
            }
    }

    private func readDirectory(_ handle: Data, entries: [SFTPFileEntry]) -> EventLoopFuture<[SFTPFileEntry]> {
        request(12) { $0.string(handle) }.flatMap { reply in
            do {
                if reply.type == 101 {
                    try self.status(reply, expected: 1)
                    return self.loop.makeSucceededFuture(entries)
                }
                guard reply.type == 104 else { throw SFTPWireError.unexpectedResponse }
                let batch = try SFTPFileEntry.readNames(reply.payload)
                guard !batch.isEmpty, entries.count + batch.count <= SFTPWire.maximumEntries else {
                    throw SFTPWireError.tooLarge
                }
                return self.readDirectory(handle, entries: entries + batch)
            } catch { return self.loop.makeFailedFuture(error) }
        }
    }

    private func upload(local: FileHandle, size: UInt64, remotePath: String) -> EventLoopFuture<Void> {
        request(7) { $0.string(try SFTPWire.path(remotePath)) }
            .flatMapThrowing { reply in
                if reply.type == 105 { throw SFTPWireError.alreadyExists }
                try self.status(reply, expected: 2) // NO_SUCH_FILE
            }
            .flatMap {
                self.request(3) { writer in
                    writer.string(try SFTPWire.path(remotePath))
                    writer.u32(0x02 | 0x08 | 0x20) // WRITE | CREATE | EXCLUSIVE
                    writer.u32(4) // permissions attribute
                    writer.u32(0o100600)
                }.flatMapThrowing(self.handle).flatMap { handle in
                    let body = self.writeFile(handle, local: local, offset: 0, size: size)
                    return self.closeAfter(handle, result: body)
                        .flatMapError { error in
                            self.remove(remotePath)
                                .map { Result<Void, Error>.success(()) }
                                .flatMapError { self.loop.makeSucceededFuture(.failure($0)) }
                                .flatMap { cleanup in
                                    switch cleanup {
                                    case .success: return self.loop.makeFailedFuture(error)
                                    case .failure: return self.loop.makeFailedFuture(SFTPWireError.partialFileMayRemain)
                                    }
                                }
                        }
                }
            }
    }

    private func writeFile(_ handle: Data, local: FileHandle, offset: UInt64, size: UInt64) -> EventLoopFuture<Void> {
        guard offset < size else { return loop.makeSucceededFuture(()) }
        do {
            guard let bytes = try local.read(upToCount: min(SFTPWire.chunkBytes, Int(size - offset))),
                  !bytes.isEmpty else { throw SFTPWireError.malformed }
            return request(6) { writer in
                writer.string(handle)
                writer.u64(offset)
                writer.string(bytes)
            }.flatMapThrowing { try self.status($0) }.flatMap {
                let next = offset + UInt64(bytes.count)
                self.report(next, size)
                return self.writeFile(handle, local: local, offset: next, size: size)
            }
        } catch { return loop.makeFailedFuture(error) }
    }

    private func download(local: FileHandle, localURL: URL, remotePath: String) -> EventLoopFuture<Void> {
        request(3) { writer in
            writer.string(try SFTPWire.path(remotePath))
            writer.u32(1) // READ
            writer.u32(0) // empty attributes
        }.flatMapThrowing(handle).flatMap { handle in
            let body = self.request(8) { $0.string(handle) }.flatMapThrowing { reply -> UInt64? in
                if reply.type == 101 { try self.status(reply); throw SFTPWireError.unexpectedResponse }
                guard reply.type == 105 else { throw SFTPWireError.unexpectedResponse }
                var reader = SFTPWire.Reader(reply.payload)
                let attributes = try SFTPFileAttributes.read(from: &reader)
                guard reader.remaining == 0 else { throw SFTPWireError.malformed }
                if let size = attributes.size, size > SFTPWire.maximumFileBytes { throw SFTPWireError.tooLarge }
                if let permissions = attributes.permissions, permissions & 0o170000 != 0o100000 {
                    throw SFTPWireError.unexpectedResponse
                }
                return attributes.size
            }.flatMap { size in
                self.readFile(handle, local: local, offset: 0, expectedSize: size)
            }
            return self.closeAfter(handle, result: body)
        }
    }

    private func readFile(_ handle: Data, local: FileHandle, offset: UInt64,
                          expectedSize: UInt64?) -> EventLoopFuture<Void> {
        request(5) { writer in
            writer.string(handle)
            writer.u64(offset)
            writer.u32(UInt32(SFTPWire.chunkBytes))
        }.flatMap { reply in
            do {
                if reply.type == 101 {
                    try self.status(reply, expected: 1)
                    if let expectedSize, offset != expectedSize { throw SFTPWireError.malformed }
                    return self.loop.makeSucceededFuture(())
                }
                guard reply.type == 103 else { throw SFTPWireError.unexpectedResponse }
                var reader = SFTPWire.Reader(reply.payload)
                let bytes = try reader.string(maximum: SFTPWire.chunkBytes)
                guard !bytes.isEmpty, reader.remaining == 0,
                      offset + UInt64(bytes.count) <= SFTPWire.maximumFileBytes,
                      expectedSize == nil || offset + UInt64(bytes.count) <= expectedSize! else {
                    throw SFTPWireError.tooLarge
                }
                try local.write(contentsOf: bytes)
                let next = offset + UInt64(bytes.count)
                self.report(next, expectedSize)
                return self.readFile(handle, local: local, offset: next, expectedSize: expectedSize)
            } catch { return self.loop.makeFailedFuture(error) }
        }
    }
}
