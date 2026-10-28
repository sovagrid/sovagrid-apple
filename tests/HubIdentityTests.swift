// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum HubIdentityTests {
    static func main() throws {
        let decoder = JSONDecoder()
        for role in ["admin", "operator", "viewer"] {
            let data = Data("{\"token\":\"fixture-session\",\"user\":{\"id\":\"fixture-user\",\"username\":\"phone\",\"role\":\"\(role)\",\"enabled\":true,\"revision\":2}}".utf8)
            let reply = try decoder.decode(HubSessionReply.self, from: data)
            precondition(reply.token == "fixture-session")
            precondition(reply.identity(fallbackUsername: "admin").role.rawValue == role)
            precondition(reply.user?.username == "phone")
            precondition(reply.user?.id == "fixture-user")
            let binding = try reply.identity(fallbackUsername: "admin").sessionBinding()
            let repeated = try reply.identity(fallbackUsername: "ignored").sessionBinding()
            precondition(binding == repeated)
        }
        let old = try decoder.decode(HubSessionReply.self, from: Data("{\"token\":\"fixture-session\"}".utf8))
        precondition(old.identity(fallbackUsername: "old-admin").role == .admin)
        precondition(old.identity(fallbackUsername: "old-admin").username == "old-admin")
        let oldBinding = try old.identity(fallbackUsername: "old-admin").sessionBinding()
        let renamedBinding = try old.identity(fallbackUsername: "other-admin").sessionBinding()
        precondition(oldBinding != renamedBinding)
        for invalid in [
            "{\"user\":null}",
            "{\"user\":{\"id\":\"fixture-user\",\"username\":\"phone\",\"role\":\"future-role\",\"enabled\":true}}",
            "{\"user\":{\"id\":\"fixture-user\",\"username\":\"phone\",\"role\":\"admin\",\"enabled\":false}}",
            "{\"user\":{\"id\":\"fixture-user\",\"username\":\"phone\",\"role\":7,\"enabled\":true}}",
            "{\"user\":{\"username\":\"phone\",\"role\":\"admin\",\"enabled\":true}}"
        ] {
            do {
                _ = try decoder.decode(HubSessionReply.self, from: Data(invalid.utf8))
                preconditionFailure("Malformed user metadata became a legacy administrator")
            } catch is DecodingError {}
        }
        let selected = try decoder.decode(HubSessionAccessReply.self, from: Data(#"{"access":{"mode":"selected","revision":4,"unrestricted_admin":false}}"#.utf8)).access
        let all = try decoder.decode(HubSessionAccessReply.self, from: Data(#"{"access":{"mode":"all","revision":0,"unrestricted_admin":true}}"#.utf8)).access
        let viewerServer = try decoder.decode(HubServer.self, from: Data(#"{"id":"server-1","name":"Gateway","online":true,"access_role":"viewer"}"#.utf8))
        let adminServer = try decoder.decode(HubServer.self, from: Data(#"{"id":"server-2","name":"Target","online":true,"access_role":"admin"}"#.utf8))
        let legacyServer = try decoder.decode(HubServer.self, from: Data(#"{"id":"server-3","name":"Old Hub","online":true}"#.utf8))
        precondition(selected.effectiveRole(for: viewerServer, globalRole: .admin) == .viewer)
        precondition(selected.effectiveRole(for: adminServer, globalRole: .operator) == .operator)
        precondition(selected.effectiveRole(for: legacyServer, globalRole: .admin) == nil)
        precondition(all.effectiveRole(for: legacyServer, globalRole: .admin) == .admin)
        precondition(HubRole.operator.canAcknowledge && !HubRole.viewer.canAcknowledge)
        for invalid in [
            #"{"access":{"mode":"selected","revision":0,"unrestricted_admin":true}}"#,
            #"{"access":{"mode":"all","revision":-1,"unrestricted_admin":true}}"#,
            #"{"access":{"mode":"future","revision":0,"unrestricted_admin":false}}"#,
            #"{"access":{"mode":"all","revision":0,"unrestricted_admin":"true"}}"#
        ] {
            do {
                _ = try decoder.decode(HubSessionAccessReply.self, from: Data(invalid.utf8))
                preconditionFailure("Malformed server access became valid")
            } catch is DecodingError {}
        }
        for invalid in [
            #"{"id":"server","name":"Gateway","online":true,"access_role":"future"}"#,
            #"{"id":"server","name":"Gateway","online":true,"access_role":null}"#
        ] {
            do {
                _ = try decoder.decode(HubServer.self, from: Data(invalid.utf8))
                preconditionFailure("Malformed per-server role became valid")
            } catch is DecodingError {}
        }
        print("Hub identity: roles, per-server caps, selected access, legacy fallback and malformed rejection passed.")
    }
}
