// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum PanelEndpointTests {
    static func main() {
        let target = SSHServer(id: UUID(), name: "target", host: "127.0.0.1", port: 2200,
                               username: "target-user", auth: .ed25519,
                               jump: SSHJumpHost(id: UUID(), host: "gateway.example", port: 22,
                                                 username: "gateway-user", auth: .password))
        precondition(PanelEndpoint.entry.address(for: target) == "gateway-user@gateway.example:22")
        precondition(PanelEndpoint.target.address(for: target) == "target-user@127.0.0.1:2200")
        precondition(!PanelEndpoint.entry.usesNestedSSH(for: target))
        precondition(PanelEndpoint.target.usesNestedSSH(for: target))

        var direct = target
        direct.jump = nil
        precondition(PanelEndpoint.entry.address(for: direct) == direct.address)
        precondition(PanelEndpoint.target.address(for: direct) == direct.address)
        precondition(!PanelEndpoint.entry.usesNestedSSH(for: direct))
        precondition(!PanelEndpoint.target.usesNestedSSH(for: direct))
        print("PanelEndpoint: entry, target and direct routes passed")
    }
}
