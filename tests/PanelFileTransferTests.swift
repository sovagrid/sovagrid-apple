// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.
import Foundation

@main enum PanelFileTransferTests {
    static let id = String(repeating: "a", count: 32)
    static func message(_ op: String, _ fields: [String: Any] = [:]) -> PanelDownloadMessage? {
        let object = ["op": op, "id": id].merging(fields) { _, new in new }
        return PanelDownloadMessage.parse(String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!)
    }
    static func fails(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("Expected rejection") } catch { }
    }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["archive.tar.gz", ".env", "ключ.pub"] { precondition(PanelDownloadContract.safeFilename(name)) }
        for name in ["", ".", "..", "../secret", "a/b", "a\\b", "x:y", " x", "x\n", String(repeating: "я", count: 121)] {
            precondition(!PanelDownloadContract.safeFilename(name))
        }
        precondition(message("start", ["filename": "server.tar.gz"]) != nil)
        precondition(message("start", ["filename": "../server.tar.gz"]) == nil)
        precondition(message("metadata", ["bytes": NSNull()]) != nil)
        for value: Any in [true, -1, 1.5, "10", PanelDownloadContract.maximumBytes + 1] {
            precondition(message("metadata", ["bytes": value]) == nil)
        }
        precondition(message("chunk", ["index": 0, "data": "QQ=="])?.data == Data([65]))
        precondition(message("chunk", ["index": true, "data": "QQ=="]) == nil)
        precondition(message("chunk", ["index": 0, "data": "QR=="]) == nil)
        precondition(message("chunk", ["index": 0, "data": Data(repeating: 1, count: 65_537).base64EncodedString()]) == nil)
        precondition(message("cancel", ["extra": true]) == nil)
        let session = try PanelDownloadSession(id: id, filename: "archive.bin", base: base)
        try session.accept(message("metadata", ["bytes": 3])!)
        try session.accept(message("chunk", ["index": 0, "data": "AAEC"])!)
        fails { try session.accept(message("chunk", ["index": 0, "data": "Aw=="])!) }
        try session.accept(message("complete", ["bytes": 3])!)
        let saved = try Data(contentsOf: session.file)
        precondition(session.complete && saved == Data([0, 1, 2]))
        let mode = try FileManager.default.attributesOfItem(atPath: session.file.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        fails { try session.accept(message("complete", ["bytes": 3])!) }
        let failed = try PanelDownloadSession(id: id, filename: "partial.bin", base: base, limit: 2)
        fails { try failed.accept(message("chunk", ["index": 0, "data": "AA=="])!) }
        fails { try failed.accept(message("metadata", ["bytes": 3])!) }
        try failed.accept(message("metadata", ["bytes": 2])!)
        try failed.accept(message("chunk", ["index": 0, "data": "AA=="])!)
        fails { try failed.accept(message("complete", ["bytes": 1])!) }
        fails { try failed.accept(message("chunk", ["index": 1, "data": "AAE="])!) }
        failed.discard(); precondition(!FileManager.default.fileExists(atPath: failed.directory.path))
        let source = base.appendingPathComponent("key.pem")
        try Data([0, 1, 2, 255]).write(to: source)
        let upload = try PanelUploadFile(source: source, base: base)
        let uploaded = try Data(contentsOf: upload.file)
        precondition(uploaded == Data([0, 1, 2, 255]))
        let tooLarge = base.appendingPathComponent("large.bin")
        try Data(repeating: 0, count: PanelUploadFile.maximumBytes + 1).write(to: tooLarge)
        fails { _ = try PanelUploadFile(source: tooLarge, base: base) }
        let symlink = base.appendingPathComponent("link.pem")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        fails { _ = try PanelUploadFile(source: symlink, base: base) }
        print("PanelFileTransfer: bounded streaming, sequence, private files and upload checks passed")
    }
}
