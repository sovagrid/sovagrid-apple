// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum SSHAuthorizedKeyInstallTests {
    static func main() throws {
        let blob = Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32] + Array(1...32))
        let publicKey = "ssh-ed25519 \(blob.base64EncodedString())"
        guard let command = SSHAuthorizedKeyInstall.command(for: publicKey) else {
            preconditionFailure("Valid Ed25519 key was rejected")
        }
        precondition(command.contains("$HOME/.ssh/authorized_keys"))
        precondition(command.contains("'\(publicKey)'"))
        precondition(command.contains("printf '\\n%s\\n'"), "Existing file may lack a final newline")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-n", "-c", command]
        try shell.run()
        shell.waitUntilExit()
        precondition(shell.terminationStatus == 0)
        for invalid in ["ssh-ed25519 invalid; touch /tmp/example", publicKey + "' ; echo secret",
                        "ssh-rsa \(blob.base64EncodedString())", publicKey + "\nnext-line"] {
            precondition(SSHAuthorizedKeyInstall.command(for: invalid) == nil)
        }
        print("Public-only authorized_keys command and shell syntax passed")
    }
}
