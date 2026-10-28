// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

/// The only remote command used for first-login assistance. No profile data is
/// interpolated into this string. SSH runs it on the same host as the panel.
enum BootstrapPassword {
    static let command = "/usr/bin/cat -- /etc/sovagrid/admin-password"
    static let maximumOutputBytes = 4096

    static func parse(_ output: [UInt8]) -> String? {
        guard !output.isEmpty, output.count <= maximumOutputBytes else { return nil }
        var bytes = output
        if bytes.last == 10 { bytes.removeLast() }
        guard (12...1024).contains(bytes.count),
              bytes.allSatisfy({ (32...126).contains($0) }),
              bytes.contains(where: { $0 != 32 }),
              let password = String(bytes: bytes, encoding: .utf8) else { return nil }
        return password
    }
}
