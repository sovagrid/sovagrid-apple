// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import CoreFoundation
import Foundation

/// Plaintext arrives only after the Web panel has decrypted the sealed VPN profile.
/// Keep this parser separate from WebKit so its bounds and canonical encoding can be tested.
struct ProfileExportPayload {
    let filename: String
    let data: Data

    private static let filenamePattern = try! NSRegularExpression(
        pattern: #"\A[a-z][a-z0-9-]{1,31}-[a-z][a-z0-9_-]{0,31}\.conf\z"#
    )

    static func parse(_ body: Any) -> ProfileExportPayload? {
        guard let text = body as? String,
              text.utf8.count <= 23_000,
              let source = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: source),
              let object = value as? [String: Any],
              Set(object.keys) == Set(["version", "filename", "data"]),
              let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.stringValue == "1",
              let filename = object["filename"] as? String,
              filenamePattern.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename))?.range
                  == NSRange(filename.startIndex..., in: filename),
              let encoded = object["data"] as? String,
              !encoded.isEmpty,
              encoded.utf8.count <= 21_846,
              encoded.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || byte == 45 || byte == 95
              }) else { return nil }

        let padded = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toLength: ((encoded.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: padded),
              (1...16_384).contains(data.count),
              data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                  .replacingOccurrences(of: "/", with: "_")
                  .replacingOccurrences(of: "=", with: "") == encoded else { return nil }
        return ProfileExportPayload(filename: filename, data: data)
    }
}

#if os(iOS)
enum ProfileExportTemporaryFiles {
    private static let prefix = "sovagrid-profile-"

    static func directory(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + id.uuidString, isDirectory: true)
    }

    /// Also covers an abrupt app termination, when dismissal callbacks cannot run.
    static func removeStaleAtLaunch() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: manager.temporaryDirectory,
                                                               includingPropertiesForKeys: [.isDirectoryKey,
                                                                                            .isSymbolicLinkKey]) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
                  let properties = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}
#endif
