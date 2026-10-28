// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

// The small, bounded subset of SFTP v3 used by the Files screen. SSH provides
// encryption and host authentication; SFTP paths are data, never shell text.
enum SFTPWireError: LocalizedError {
    case malformed
    case tooLarge
    case unsupportedVersion
    case invalidPath
    case remoteStatus(UInt32)
    case unexpectedResponse
    case cancelled
    case timedOut
    case alreadyExists
    case partialFileMayRemain

    var errorDescription: String? {
        switch self {
        case .malformed: return "Сервер прислал повреждённый ответ SFTP."
        case .tooLarge: return "Превышен лимит размера файла или ответа SFTP."
        case .unsupportedVersion: return "Сервер не поддерживает SFTP версии 3."
        case .invalidPath: return "Путь SFTP слишком длинный или содержит недопустимые символы."
        case .remoteStatus(let code): return "SFTP-сервер отказал в операции (код \(code))."
        case .unexpectedResponse: return "SFTP-сервер прислал неожиданный ответ."
        case .cancelled: return "Передача отменена."
        case .timedOut: return "Время ожидания SFTP-сервера истекло."
        case .alreadyExists: return "Файл с таким именем уже есть на сервере."
        case .partialFileMayRemain: return "Передача прервана. На сервере может остаться неполный файл."
        }
    }
}

enum SFTPWire {
    static let maximumFileBytes: UInt64 = 128 * 1024 * 1024
    static let chunkBytes = 32 * 1024
    static let maximumPacketBytes = 512 * 1024
    static let maximumEntries = 1_000

    static func packet(_ type: UInt8, _ payload: Data) throws -> Data {
        guard payload.count + 1 <= maximumPacketBytes else { throw SFTPWireError.tooLarge }
        var writer = Writer()
        writer.u32(UInt32(payload.count + 1))
        writer.byte(type)
        writer.bytes(payload)
        return writer.data
    }

    static func path(_ value: String) throws -> Data {
        let bytes = Data(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 4_096,
              !bytes.contains(0), !bytes.contains(10), !bytes.contains(13) else {
            throw SFTPWireError.invalidPath
        }
        return bytes
    }

    static func joined(_ directory: String, _ filename: String) throws -> String {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\0"),
              !filename.contains("\n"), !filename.contains("\r") else {
            throw SFTPWireError.invalidPath
        }
        let result = directory.isEmpty || directory == "." ? filename
            : directory == "/" ? "/" + filename : directory.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + filename
        let absoluteResult = directory.hasPrefix("/") && directory != "/" ? "/" + result : result
        _ = try path(absoluteResult)
        return absoluteResult
    }

    struct Writer {
        private(set) var data = Data()
        mutating func byte(_ value: UInt8) { data.append(value) }
        mutating func bytes(_ value: Data) { data.append(value) }
        mutating func u32(_ value: UInt32) {
            data.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24),
                                     UInt8(truncatingIfNeeded: value >> 16),
                                     UInt8(truncatingIfNeeded: value >> 8),
                                     UInt8(truncatingIfNeeded: value)])
        }
        mutating func u64(_ value: UInt64) {
            u32(UInt32(truncatingIfNeeded: value >> 32))
            u32(UInt32(truncatingIfNeeded: value))
        }
        mutating func string(_ value: Data) {
            u32(UInt32(value.count))
            bytes(value)
        }
        mutating func string(_ value: String) { string(Data(value.utf8)) }
    }

    struct Reader {
        let data: Data
        private(set) var offset = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - offset }
        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw SFTPWireError.malformed }
            let result = data.subdata(in: offset..<(offset + count))
            offset += count
            return result
        }
        mutating func byte() throws -> UInt8 {
            guard remaining >= 1 else { throw SFTPWireError.malformed }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func u32() throws -> UInt32 {
            let b = try bytes(4)
            return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        mutating func u64() throws -> UInt64 {
            (UInt64(try u32()) << 32) | UInt64(try u32())
        }
        mutating func string(maximum: Int = maximumPacketBytes) throws -> Data {
            let length = try u32()
            guard length <= maximum else { throw SFTPWireError.tooLarge }
            return try bytes(Int(length))
        }
        mutating func utf8(maximum: Int = 4_096) throws -> String {
            guard let text = String(data: try string(maximum: maximum), encoding: .utf8) else {
                throw SFTPWireError.malformed
            }
            return text
        }
    }
}

struct SFTPFileAttributes {
    let size: UInt64?
    let permissions: UInt32?
    var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
    var isRegularFile: Bool { permissions.map { $0 & 0o170000 == 0o100000 } ?? false }

    static func read(from reader: inout SFTPWire.Reader) throws -> Self {
        let flags = try reader.u32()
        guard flags & ~UInt32(0x8000_000F) == 0 else { throw SFTPWireError.malformed }
        let size = flags & 1 != 0 ? try reader.u64() : nil
        if flags & 2 != 0 { _ = try reader.u32(); _ = try reader.u32() }
        let permissions = flags & 4 != 0 ? try reader.u32() : nil
        if flags & 8 != 0 { _ = try reader.u32(); _ = try reader.u32() }
        if flags & 0x8000_0000 != 0 {
            let count = try reader.u32()
            guard count <= 64 else { throw SFTPWireError.tooLarge }
            for _ in 0..<count {
                _ = try reader.string()
                _ = try reader.string()
            }
        }
        return .init(size: size, permissions: permissions)
    }
}

struct SFTPFileEntry: Identifiable {
    let name: String
    let attributes: SFTPFileAttributes
    var id: String { name }
    var isDirectory: Bool { attributes.isDirectory }

    static func readNames(_ payload: Data) throws -> [Self] {
        var reader = SFTPWire.Reader(payload)
        let count = try reader.u32()
        guard count <= SFTPWire.maximumEntries else { throw SFTPWireError.tooLarge }
        var result = [Self]()
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            let name = try reader.utf8()
            _ = try reader.string() // Display-only longname is not used.
            let attrs = try SFTPFileAttributes.read(from: &reader)
            guard !name.contains("/") && !name.contains("\0") else { throw SFTPWireError.malformed }
            if name != "." && name != ".." { result.append(.init(name: name, attributes: attrs)) }
        }
        guard reader.remaining == 0 else { throw SFTPWireError.malformed }
        return result
    }
}
