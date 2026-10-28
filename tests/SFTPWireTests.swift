// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

private func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

private func readExactly(_ handle: FileHandle, _ count: Int) throws -> Data {
    var result = Data()
    while result.count < count {
        let next = try handle.read(upToCount: count - result.count) ?? Data()
        guard !next.isEmpty else { throw SFTPWireError.malformed }
        result.append(next)
    }
    return result
}

private final class LocalSFTP {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var id: UInt32 = 0

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        var initPacket = SFTPWire.Writer()
        initPacket.u32(3)
        let version = try exchange(type: 1, payload: initPacket.data)
        var reader = SFTPWire.Reader(version.payload)
        let versionNumber = try reader.u32()
        check(version.type == 2 && versionNumber == 3, "SFTP v3 negotiation")
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    func request(_ type: UInt8, _ build: (inout SFTPWire.Writer) -> Void) throws -> (UInt8, Data) {
        id += 1
        var writer = SFTPWire.Writer()
        writer.u32(id)
        build(&writer)
        let reply = try exchange(type: type, payload: writer.data)
        var reader = SFTPWire.Reader(reply.payload)
        check(try reader.u32() == id, "SFTP response id")
        return (reply.type, try reader.bytes(reader.remaining))
    }

    private func exchange(type: UInt8, payload: Data) throws -> (type: UInt8, payload: Data) {
        try input.fileHandleForWriting.write(contentsOf: SFTPWire.packet(type, payload))
        var reader = SFTPWire.Reader(try readExactly(output.fileHandleForReading, 4))
        let length = try reader.u32()
        check(length > 0 && length <= SFTPWire.maximumPacketBytes, "bounded SFTP packet")
        var packet = SFTPWire.Reader(try readExactly(output.fileHandleForReading, Int(length)))
        return (try packet.byte(), try packet.bytes(packet.remaining))
    }
}

@main
struct SFTPWireTests {
    static func main() throws {
        let binary = Data([0, 1, 2, 0, 255, 128, 10, 13]) + Data((0..<30_000).map { UInt8($0 % 251) })
        check(try SFTPWire.joined("/tmp/foo", "a.bin") == "/tmp/foo/a.bin", "absolute join")
        check(try SFTPWire.joined(".", "a.bin") == "a.bin", "relative join")
        check((try? SFTPWire.joined(".", "../bad")) == nil, "slash rejected")
        check((try? SFTPWire.path(String(repeating: "x", count: 4_097))) == nil, "long path rejected")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sovagrid-sftp-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try LocalSFTP()
        let destination = folder.appendingPathComponent("binary.bin").path

        let opened = try server.request(3) { writer in
            writer.string(destination)
            writer.u32(0x02 | 0x08 | 0x20)
            writer.u32(4)
            writer.u32(0o100600)
        }
        check(opened.0 == 102, "exclusive SFTP OPEN")
        var openedReader = SFTPWire.Reader(opened.1)
        let uploadHandle = try openedReader.string()

        let written = try server.request(6) { writer in
            writer.string(uploadHandle)
            writer.u64(0)
            writer.string(binary)
        }
        try expectOK(written)
        try expectOK(server.request(4) { $0.string(uploadHandle) })
        check(try Data(contentsOf: URL(fileURLWithPath: destination)) == binary, "binary upload exact")
        let mode = try FileManager.default.attributesOfItem(atPath: destination)[.posixPermissions] as? NSNumber
        check(mode?.intValue == 0o600, "remote file mode 0600")
        let secondOpen = try server.request(3) { writer in
            writer.string(destination)
            writer.u32(0x02 | 0x08 | 0x20)
            writer.u32(0)
        }
        check(secondOpen.0 == 101, "exclusive open refuses existing file")
        check(try Data(contentsOf: URL(fileURLWithPath: destination)) == binary,
              "existing binary never overwritten")

        let dir = try server.request(11) { $0.string(folder.path) }
        check(dir.0 == 102, "directory open")
        var dirReader = SFTPWire.Reader(dir.1)
        let directoryHandle = try dirReader.string()
        let listing = try server.request(12) { $0.string(directoryHandle) }
        check(listing.0 == 104, "directory list")
        let names = try SFTPFileEntry.readNames(listing.1)
        check(names.contains { $0.name == "binary.bin" && $0.attributes.size == UInt64(binary.count) },
              "directory attributes")
        try expectOK(server.request(4) { $0.string(directoryHandle) })

        let input = try server.request(3) { writer in
            writer.string(destination)
            writer.u32(1)
            writer.u32(0)
        }
        check(input.0 == 102, "read open")
        var inputReader = SFTPWire.Reader(input.1)
        let readHandle = try inputReader.string()
        let stats = try server.request(8) { $0.string(readHandle) }
        check(stats.0 == 105, "FSTAT")
        var statsReader = SFTPWire.Reader(stats.1)
        let attrs = try SFTPFileAttributes.read(from: &statsReader)
        check(attrs.size == UInt64(binary.count), "FSTAT size")
        let read = try server.request(5) { writer in
            writer.string(readHandle)
            writer.u64(0)
            writer.u32(UInt32(SFTPWire.chunkBytes))
        }
        check(read.0 == 103, "READ data")
        var readReader = SFTPWire.Reader(read.1)
        check(try readReader.string() == binary, "binary download exact")
        try expectOK(server.request(4) { $0.string(readHandle) })
        print("SFTP wire fixture: binary upload/download, listing, FSTAT, permissions, and path bounds passed.")
    }

    private static func expectOK(_ reply: (UInt8, Data)) throws {
        check(reply.0 == 101, "SFTP status response")
        var reader = SFTPWire.Reader(reply.1)
        check(try reader.u32() == 0, "SFTP status OK")
    }
}
