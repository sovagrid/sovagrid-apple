// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Jigokuraku01
// Additional author attribution terms: see ATTRIBUTION.md.
import Foundation
import Darwin

@main enum PanelRestoreTransferTests {
    static let session = String(repeating: "a", count: 32)
    static let identity = String(repeating: "b", count: 32)
    static let handle = String(repeating: "c", count: 64)
    static func message(_ action: String, _ fields: [String: Any] = [:]) -> PanelRestoreMessage? {
        let value = ["action": action, "session": session, "id": identity].merging(fields) { _, new in new }
        return PanelRestoreMessage.parse(String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!)
    }
    static func fails(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected a bounded rejection") } catch { }
    }
    static func sparse(_ path: URL, _ bytes: Int64) throws {
        let fd = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        precondition(fd >= 0); defer { Darwin.close(fd) }
        precondition(Darwin.ftruncate(fd, off_t(bytes)) == 0)
    }
    static func fifoProbe(_ path: String) {
        let files = PanelRestoreFiles()
        defer { files.close() }
        fails { _ = try files.add(URL(fileURLWithPath: path)) }
    }
    static func testGrammar() {
        precondition(message("pick") != nil && message("release") != nil)
        precondition(message("read", ["handle": handle, "offset": 0, "length": 262_144]) != nil)
        precondition(message("read", ["handle": handle, "offset": PanelRestoreContract.fileBytes, "length": 1]) != nil)
        for action in ["open-path", "write", "delete", ""] { precondition(message(action) == nil) }
        precondition(message("pick", ["path": "/private/file"]) == nil)
        precondition(message("release", ["extra": true]) == nil)
        for token in ["", String(repeating: "A", count: 32), String(repeating: "a", count: 31), "../file"] {
            precondition(message("pick", ["session": token]) == nil)
        }
        for value: Any in [true, -1, 0.5, "1", PanelRestoreContract.fileBytes + 1] {
            precondition(message("read", ["handle": handle, "offset": value, "length": 1]) == nil)
        }
        for value: Any in [true, -1, 0, 0.5, "1", 262_145] {
            precondition(message("read", ["handle": handle, "offset": 0, "length": value]) == nil)
        }
        precondition(message("read", ["handle": String(repeating: "A", count: 64), "offset": 0, "length": 1]) == nil)
        precondition(PanelRestoreMessage.parse(String(repeating: "x", count: 4097)) == nil)
        precondition(PanelRestoreContract.validRange(size: 10, offset: 9, length: 1))
        for (size, offset, length): (Int64, Int64, Int) in [
            (0, 0, 1), (10, -1, 1), (10, 10, 1), (10, 9, 2),
            (PanelRestoreContract.fileBytes, 0, 262_145), (10, 0, 0),
            (PanelRestoreContract.fileBytes + 1, 0, 1), (10, Int64.max, 1), (10, Int64.min, 1)
        ] { precondition(!PanelRestoreContract.validRange(size: size, offset: offset, length: length)) }
    }
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--fifo-probe" {
            fifoProbe(CommandLine.arguments[2]); return
        }
        testGrammar()
        // Foundation's default solidus escaping can double an all0xff
        // base64 block. The production reply serializer must keep every valid
        // 256KiB binary read inside its bound rather than silently dropping it.
        let slashBytes = Data(repeating: 255, count: PanelRestoreContract.readBytes)
        let encoded = slashBytes.base64EncodedString()
        let reply = PanelRestoreContract.replyJSON(["ok": true, "data": encoded])!
        precondition(reply.utf8.count <= 400_000 && !reply.contains("\\/"))
        let decoded = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
        precondition(Data(base64Encoded: decoded["data"] as! String) == slashBytes)
        precondition(PanelRestoreContract.replyJSON(["ok": true, "data": String(repeating: "x", count: 400_001)]) == nil)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sovagrid-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = base.appendingPathComponent("images.tar")
        let size = 6 * 1024 * 1024 + 37
        let expected = Data((0..<size).map { UInt8($0 % 251) })
        try expected.write(to: file)
        let pool = PanelRestoreFiles()
        let descriptor = try pool.add(file)
        let selected = descriptor["handle"] as! String
        precondition(PanelRestoreContract.token(selected, count: 64))
        precondition(descriptor["name"] as? String == "images.tar")
        precondition(descriptor["size"] as? Int64 == Int64(size))
        precondition(descriptor.keys.sorted() == ["handle", "name", "size"])
        for offset in [0, 4 * 1024 * 1024 - 7, size - 262_144] {
            let actual = try pool.read(handle: selected, offset: Int64(offset), length: 262_144)
            precondition(actual == expected.subdata(in: offset..<(offset + 262_144)))
        }
        fails { _ = try pool.read(handle: selected, offset: 0, length: 262_145) }
        fails { _ = try pool.read(handle: selected, offset: Int64(size), length: 1) }
        fails { _ = try pool.read(handle: "unknown", offset: 0, length: 1) }

        // Restore mtime after an in-place mutation: ctime must still invalidate
        // a retained descriptor even when its inode and size are unchanged.
        let update = Darwin.open(file.path, O_RDWR | O_CLOEXEC)
        precondition(update >= 0)
        var before = stat(); precondition(Darwin.fstat(update, &before) == 0)
        var changed: UInt8 = 255
        precondition(Darwin.pwrite(update, &changed, 1, 0) == 1)
        var times = [before.st_atimespec, before.st_mtimespec]
        precondition(Darwin.futimens(update, &times) == 0)
        Darwin.close(update)
        fails { _ = try pool.read(handle: selected, offset: 0, length: 1) }
        pool.close(); pool.close()
        fails { _ = try pool.read(handle: selected, offset: 0, length: 1) }
        fails { _ = try pool.add(file) }

        let identical = base.appendingPathComponent("same.json")
        try Data("{}".utf8).write(to: identical)
        let replaced = PanelRestoreFiles(); defer { replaced.close() }
        let old = try replaced.add(identical)["handle"] as! String
        try Data("{}".utf8).write(to: identical, options: .atomic)
        fails { _ = try replaced.read(handle: old, offset: 0, length: 2) }

        let shape = PanelRestoreFiles(); defer { shape.close() }
        let link = base.appendingPathComponent("link.tar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        fails { _ = try shape.add(link) }
        fails { _ = try shape.add(base) }
        let empty = base.appendingPathComponent("empty.tar"); try Data().write(to: empty)
        fails { _ = try shape.add(empty) }
        let fifo = base.appendingPathComponent("stream.tar")
        precondition(Darwin.mkfifo(fifo.path, 0o600) == 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        process.arguments = ["--fifo-probe", fifo.path]
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 3) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
            preconditionFailure("Nonregular FIFO open blocked")
        }
        precondition(process.terminationStatus == 0)

        let many = PanelRestoreFiles(); defer { many.close() }
        for index in 0..<5 {
            let name = base.appendingPathComponent("part-\(index).json")
            try Data([UInt8(index)]).write(to: name)
            _ = try many.add(name)
        }
        fails { _ = try many.add(file) }

        // Sparse fixtures check real descriptor size arithmetic without reading
        // or allocating gigabytes in the test process.
        let maximum = base.appendingPathComponent("maximum.tar")
        let second = base.appendingPathComponent("second.tar")
        let excessive = base.appendingPathComponent("too-big.tar")
        try sparse(maximum, PanelRestoreContract.fileBytes)
        try sparse(second, PanelRestoreContract.fileBytes)
        try sparse(excessive, PanelRestoreContract.fileBytes + 1)
        let capacity = PanelRestoreFiles(); defer { capacity.close() }
        let maximumHandle = try capacity.add(maximum)["handle"] as! String
        _ = try capacity.add(second)
        let last = try capacity.read(handle: maximumHandle, offset: PanelRestoreContract.fileBytes - 1, length: 1)
        precondition(last == Data([0]))
        fails { _ = try capacity.add(file) }
        fails { _ = try shape.add(excessive) }
        print("PanelRestore: grammar, bounded FD reads, fingerprint mutation, closure, FIFO, count and sparse-size limits passed")
    }
}
