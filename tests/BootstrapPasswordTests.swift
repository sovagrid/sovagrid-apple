// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum BootstrapPasswordTests {
    static func main() {
        precondition(BootstrapPassword.command == "/usr/bin/cat -- /etc/sovagrid/admin-password")
        let sample = String(repeating: "aB3_-", count: 9)
        precondition(BootstrapPassword.parse(Array((sample + "\n").utf8)) == sample)
        precondition(BootstrapPassword.parse(Array(sample.utf8)) == sample)
        for invalid in [
            "", "short", "\n", sample + "\n\n", sample + "\r\n",
            sample + "\u{0}", sample + "\nsecond", String(repeating: "x", count: 1025),
            String(repeating: " ", count: 20)
        ] {
            precondition(BootstrapPassword.parse(Array(invalid.utf8)) == nil)
        }
        precondition(BootstrapPassword.parse(Array(repeating: 65, count: 4097)) == nil)
        precondition(BootstrapPassword.parse([0xFF] + Array(sample.utf8)) == nil)
        print("BootstrapPassword: fixed command and bounded parsing passed")
    }
}
