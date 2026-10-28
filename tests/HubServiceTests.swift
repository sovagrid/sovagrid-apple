// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum HubServiceTests {
    static func main() throws {
        for valid in ["nginx.service", "postgresql@main.service", "A_1.2-3.service"] {
            precondition(HubServiceUnit.valid(valid), valid)
        }
        for invalid in ["", "ssh", "@bad.service", "nginx@.service", "nginx.socket",
                        "../nginx.service", "nginx.service;id", "тест.service",
                        String(repeating: "a", count: 89) + ".service"] {
            precondition(!HubServiceUnit.valid(invalid), invalid)
        }
        for reserved in ["ssh.service", "sshd@host.service", "systemd-networkd.service",
                         "docker.service", "sovagrid-agent.service", "reverse-tunnel.service",
                         "wg-quick@wg0.service", "AmneziaWG.service"] {
            precondition(HubServiceUnit.protected(reserved), reserved)
        }
        precondition(!HubServiceUnit.protected("nginx.service"))
        precondition(!HubServiceUnit.protected("postgresql@main.service"))

        let decoder = JSONDecoder()
        let server = try decoder.decode(HubServer.self, from: Data(#"{"id":"server","name":"Gateway","online":true,"remote_commands_enabled":true}"#.utf8))
        precondition(server.remoteCommandsEnabled)
        let legacy = try decoder.decode(HubServer.self, from: Data(#"{"id":"server","name":"Old","online":true}"#.utf8))
        precondition(!legacy.remoteCommandsEnabled)
        let observed = try decoder.decode(HubServiceControl.self, from: Data(#"{"source_status":"ok","unit":"nginx.service","observed_at":1700000000,"load_state":"loaded","active_state":"active","sub_state":"running"}"#.utf8))
        precondition(observed.sourceStatus == "ok" && observed.activeState == "active")
        let unavailable = try decoder.decode(HubServiceControl.self, from: Data(#"{"source_status":"unavailable","unit":"nginx.service","observed_at":null,"load_state":null,"active_state":null,"sub_state":null}"#.utf8))
        precondition(unavailable.observedAt == nil)
        let result = try decoder.decode(HubServiceMutationResult.self, from: Data(#"{"action":"restart","unit":"nginx.service","result":"ok","load_state":"loaded","active_state":"active","sub_state":"running"}"#.utf8))
        precondition(result.action == .restart && result.activeState == "active")

        for invalid in [
            #"{"source_status":"ok","unit":"nginx.service","observed_at":null,"load_state":"loaded","active_state":"active","sub_state":"running"}"#,
            #"{"source_status":"ok","unit":"nginx.service","observed_at":1700000000,"load_state":"loaded","active_state":"active","sub_state":"RUNNING"}"#,
            #"{"source_status":"unavailable","unit":"nginx.service","observed_at":null,"load_state":"loaded","active_state":null,"sub_state":null}"#
        ] {
            do {
                _ = try decoder.decode(HubServiceControl.self, from: Data(invalid.utf8))
                preconditionFailure("Invalid service status was accepted")
            } catch is DecodingError { }
        }
        print("Hub service: unit grammar, protected units, old Hub gating and bounded state decoding passed.")
    }
}
