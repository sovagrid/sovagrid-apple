// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum HubContainerTests {
    static func main() throws {
        let id = String(repeating: "a", count: 64)
        precondition(HubContainerID.valid(id))
        for invalid in ["a", String(repeating: "A", count: 64),
                        String(repeating: "g", count: 64), String(repeating: "a", count: 65)] {
            precondition(!HubContainerID.valid(invalid))
        }
        for (name, image) in [("sovagrid-hub", "nginx"),
                              ("backup", "registry.example.com/amnezia/awg:latest"),
                              ("reverse-tunnel", "alpine"),
                              ("sshd", "ubuntu"), ("docker-proxy", "busybox"),
                              ("site", ":"), ("site", "/")] {
            precondition(HubContainerID.protected(name: name, image: image))
        }
        precondition(!HubContainerID.protected(name: "site", image: "registry.example.com/nginx:stable"))

        let decoder = JSONDecoder()
        let details = #"{"containers":{"version":1,"collected_at":1700000000,"engines":[{"engine":"docker","source_status":"ok","reason":null,"truncated":false,"containers":[{"id":""# + id + #"","name":"site","image":"nginx:stable","state":"running","health":"healthy","restarts":0,"cpu_percent":1.5,"memory_bytes":1024}]},{"engine":"podman","source_status":"unavailable","reason":"no_socket","truncated":false,"containers":[]}]}}"#
        let metric = try decoder.decode(HubMetricDetails.self, from: Data(details.utf8))
        precondition(metric.containers?.completeDocker?.containers.first?.id == id)
        let truncated = details.replacingOccurrences(of: #""truncated":false"#, with: #""truncated":true"#, range: details.range(of: #""truncated":false"#))
        let truncatedMetric = try decoder.decode(HubMetricDetails.self, from: Data(truncated.utf8))
        precondition(truncatedMetric.containers?.completeDocker == nil)

        let control = try decoder.decode(HubContainerControl.self, from: Data((#"{"source_status":"ok","engine":"docker","id":""# + id + #"","observed_at":1700000000,"state":"running"}"#).utf8))
        precondition(control.sourceStatus == "ok" && control.state == .running)
        let unavailable = try decoder.decode(HubContainerControl.self, from: Data((#"{"source_status":"unavailable","engine":"docker","id":""# + id + #"","observed_at":null,"state":null}"#).utf8))
        precondition(unavailable.state == nil)
        let mutation = try decoder.decode(HubContainerMutationResult.self, from: Data((#"{"action":"restart","id":""# + id + #"","result":"ok","state":"running"}"#).utf8))
        precondition(mutation.action == .restart && mutation.state == .running)

        for invalid in [
            #"{"source_status":"ok","engine":"docker","id":""# + id + #"","observed_at":null,"state":"running"}"#,
            #"{"source_status":"ok","engine":"podman","id":""# + id + #"","observed_at":1700000000,"state":"running"}"#,
            #"{"source_status":"unavailable","engine":"docker","id":""# + id + #"","observed_at":null,"state":"running"}"#,
            #"{"source_status":"ok","engine":"docker","id":"short","observed_at":1700000000,"state":"running"}"#
        ] {
            do {
                _ = try decoder.decode(HubContainerControl.self, from: Data(invalid.utf8))
                preconditionFailure("Invalid container status was accepted")
            } catch is DecodingError { }
        }
        do {
            _ = try decoder.decode(HubContainerMutationResult.self, from: Data((#"{"action":"stop","id":""# + id + #"","result":"ok","state":"running"}"#).utf8))
            preconditionFailure("Contradictory stop result was accepted")
        } catch is DecodingError { }
        print("Hub Docker: full ID, protected inventory, complete snapshot and bounded result decoding passed.")
    }
}
