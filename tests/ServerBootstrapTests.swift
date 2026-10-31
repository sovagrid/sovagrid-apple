// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum ServerBootstrapTests {
    static func main() throws {
        let start = SovaGridFirstInstall.startCommand
        let status = SovaGridFirstInstall.statusCommand
        precondition(start.contains("systemd-run --quiet --collect --unit=sovagrid-first-install"))
        precondition(start.contains("server-v0.12.0/SovaGrid-server-source.tar.gz"))
        precondition(start.contains(SovaGridFirstInstall.sourceSHA256))
        precondition(start.contains(SovaGridFirstInstall.manifestSHA256))
        precondition(start.contains("/run/sovagrid-first-install.lock"))
        precondition(start.contains("head -c 67108865"))
        precondition(status.contains("/var/lib/sovagrid-first-install"))
        for (shell, command) in [("/bin/bash", start), ("/bin/sh", status)] {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: shell)
            check.arguments = ["-n", "-c", command]
            try check.run()
            check.waitUntilExit()
            precondition(check.terminationStatus == 0)
        }
        precondition(SovaGridFirstInstall.startAccepted(Array("SG_INSTALL_START_V1:OK\n".utf8), exitStatus: 0))
        precondition(!SovaGridFirstInstall.startAccepted(Array("SG_INSTALL_START_V1:OK\n".utf8), exitStatus: 1))
        precondition(SovaGridFirstInstall.parseStatus(Array("SG_INSTALL_JOB_V1:none\n".utf8), exitStatus: 0).state == .none)
        let running = SovaGridFirstInstall.parseStatus(Array("SG_INSTALL_JOB_V1:running:RUN:NONE\n".utf8), exitStatus: 0)
        precondition(running.state == .running && running.stage == "RUN")
        let failed = SovaGridFirstInstall.parseStatus(Array("SG_INSTALL_JOB_V1:failed:RUN:RESULT\n".utf8), exitStatus: 0)
        precondition(failed.state == .failed && failed.reason == "RESULT")
        precondition(SovaGridFirstInstall.parseStatus(Array("SG_INSTALL_JOB_V1:done:DONE:NONE\n".utf8), exitStatus: 0).state == .done)
        for invalid in ["SG_INSTALL_JOB_V1:none", "SG_INSTALL_JOB_V1:running:EVIL:NONE\n", "SG_INSTALL_JOB_V1:done:DONE:NONE\nmore",
                        "SG_INSTALL_JOB_V1:failed:RUN:secret\n", "SG_INSTALL_JOB_V1:none\r\n"] {
            precondition(SovaGridFirstInstall.parseStatus(Array(invalid.utf8), exitStatus: 0).state == .unknown)
        }
        precondition(SovaGridFirstInstall.parseStatus(Array("SG_INSTALL_JOB_V1:none\n".utf8), exitStatus: nil).state == .unknown)
        print("First install: fixed detached job, shell syntax and strict status parser passed")
    }
}
