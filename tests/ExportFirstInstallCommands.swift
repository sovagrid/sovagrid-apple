// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

/// CI exports the exact strings the Apple app sends through its SSH channel.
@main
enum ExportFirstInstallCommands {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ExportError.arguments }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let files = ["start.command": SovaGridFirstInstall.startCommand,
                     "status.command": SovaGridFirstInstall.statusCommand]
        guard files["start.command"]?.contains(SovaGridFirstInstall.sourceSHA256) == true,
              files["start.command"]?.contains(SovaGridFirstInstall.manifestSHA256) == true else {
            throw ExportError.unpinned
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        for (name, command) in files {
            let target = root.appendingPathComponent(name, isDirectory: false)
            try command.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: target.path)
        }
        print("Exported fixed Apple SSH commands for disposable CI")
    }

    enum ExportError: Error { case arguments, unpinned }
}
