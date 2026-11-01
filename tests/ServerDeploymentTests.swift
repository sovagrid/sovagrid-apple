// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation
import CryptoKit

@main
enum ServerDeploymentTests {
    static func main() throws {
        for state in [ServerDeployment.managed, .agentOnly, .missing, .conflict, .unsupported, .unknown] {
            let marker = "SG_STATUS_V1:\(state.rawValue)\n"
            precondition(ServerDeployment.parse(Array(marker.utf8), exitStatus: 0) == state)
        }
        for invalid in ["missing", "SG_STATUS_V2:missing\n", "SG_STATUS_V1:missing \n",
                        "SG_STATUS_V1:missing\nmanaged", "SG_STATUS_V1:missing\r\n",
                        "SG_STATUS_V1:other\n", String(repeating: "A", count: 65)] {
            precondition(ServerDeployment.parse(Array(invalid.utf8), exitStatus: 0) == .unknown)
        }
        precondition(ServerDeployment.parse(Array("SG_STATUS_V1:missing\n".utf8), exitStatus: nil) == .unknown)
        precondition(ServerDeployment.parse(Array("SG_STATUS_V1:missing\n".utf8), exitStatus: 1) == .unknown)

        let command = ServerDeploymentProbe.command
        precondition(command.contains("sudo -n /bin/sh -c"))
        precondition(command.contains("/var/lib/sovagrid-agent-enrollment"))
        precondition(command.contains("/var/lib/sovagrid-first-install"))
        precondition(!command.contains("curl") && !command.contains("wget") && !command.contains("run.sh"))
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", "-c", command]
        try check.run()
        check.waitUntilExit()
        precondition(check.terminationStatus == 0)

        // Decode the compiled shell literal and verify the exact reviewed
        // predicate, including both language and shell escaping.
        let prefix = "then /bin/sh -c "
        let suffix = "; elif [ -x /usr/bin/sudo ]"
        let quoteStart = command.range(of: prefix)!.upperBound
        let quoteEnd = command.range(of: suffix, range: quoteStart..<command.endIndex)!.lowerBound
        let decode = Process()
        let decoded = Pipe()
        decode.executableURL = URL(fileURLWithPath: "/bin/sh")
        decode.arguments = ["-c", "printf '%s' " + String(command[quoteStart..<quoteEnd])]
        decode.standardOutput = decoded
        try decode.run()
        let script = String(data: decoded.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        decode.waitUntilExit()
        precondition(decode.terminationStatus == 0)
        let bodyStart = script.range(of: "<<'SG_MANAGED_VPN_SOURCE'\n")!.upperBound
        let bodyEnd = script.range(of: "raise SystemExit(0 if managed_vpn_source() else 1)\nSG_MANAGED_VPN_SOURCE\n",
                                   range: bodyStart..<script.endIndex)!.lowerBound
        let body = String(script[bodyStart..<bodyEnd])
        let predicateHash = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        precondition(predicateHash == "a830cdbff325dd49fff710fd6d24e5f50e846adf7365f40ecadaa62aaa194bb9")
        let python = Process()
        let pythonInput = Pipe()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-B", "-I", "-c", "import sys; compile(sys.stdin.read(), '<fixed-vpn-status>', 'exec')"]
        python.standardInput = pythonInput
        try python.run()
        try pythonInput.fileHandleForWriting.write(contentsOf: Data(body.utf8))
        try pythonInput.fileHandleForWriting.close()
        python.waitUntilExit()
        precondition(python.terminationStatus == 0)

        let grant = String(repeating: "A", count: 43)
        let response = "{\"protocol\":1,\"grant\":\"\(grant)\",\"expires_at\":1800000000,\"username\":\"admin\"}\n"
        precondition(SSHGrantResponse.parse(Array(response.utf8), exitStatus: 0) == grant)
        precondition(SSHGrantResponse.javaScriptLiteral(grant) == "\"\(grant)\"")
        for invalid in [
            response.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":2"),
            response.replacingOccurrences(of: "\"grant\":\"\(grant)\"", with: "\"grant\":\"abc\""),
            response.replacingOccurrences(of: "\"username\":\"admin\"", with: "\"username\":\"admin\",\"extra\":1"),
            response + "second line\n", String(repeating: "A", count: 513),
        ] {
            precondition(SSHGrantResponse.parse(Array(invalid.utf8), exitStatus: 0) == nil)
        }
        precondition(SSHGrantResponse.parse(Array(response.utf8), exitStatus: nil) == nil)
        precondition(SSHGrantResponse.command.contains("sudo -n docker compose"))
        let grantSyntax = Process()
        grantSyntax.executableURL = URL(fileURLWithPath: "/bin/sh")
        grantSyntax.arguments = ["-n", "-c", SSHGrantResponse.command]
        try grantSyntax.run()
        grantSyntax.waitUntilExit()
        precondition(grantSyntax.terminationStatus == 0)
        print("ServerDeployment: status, one-use grant parsing, fixed commands and shell syntax passed")
    }
}
