// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

/// A command to run as the SSH user whose authorized_keys should accept this key.
enum SSHAuthorizedKeyInstall {
    static func command(for publicKey: String) -> String? {
        let fields = publicKey.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "ssh-ed25519",
              !fields[1].isEmpty,
              fields[1].utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 43 || byte == 47 || byte == 61
              }),
              let blob = Data(base64Encoded: String(fields[1])), blob.count == 51,
              Array(blob.prefix(4)) == [0, 0, 0, 11],
              Array(blob[4..<15]) == Array("ssh-ed25519".utf8),
              Array(blob[15..<19]) == [0, 0, 0, 32] else { return nil }
        let quotedKey = "'\(publicKey)'"
        return "umask 077; mkdir -p \"$HOME/.ssh\" && chmod 700 \"$HOME/.ssh\" && touch \"$HOME/.ssh/authorized_keys\" && chmod 600 \"$HOME/.ssh/authorized_keys\" && (grep -Fqx -- \(quotedKey) \"$HOME/.ssh/authorized_keys\" || printf '\\n%s\\n' \(quotedKey) >> \"$HOME/.ssh/authorized_keys\")"
    }
}
