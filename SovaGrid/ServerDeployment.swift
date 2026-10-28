// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

/// A root or passwordless-sudo read-only probe over the already trusted SSH channel.
enum ServerDeployment: String {
    case managed
    case agentOnly = "agent_only"
    case missing
    case conflict
    case unsupported
    case unknown

    static let maximumOutputBytes = 64

    static func parse(_ output: [UInt8], exitStatus: Int?) -> ServerDeployment {
        guard exitStatus == 0, (1...maximumOutputBytes).contains(output.count),
              let text = String(bytes: output, encoding: .ascii) else { return .unknown }
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard line.hasPrefix("SG_STATUS_V1:"), !line.contains("\n"), !line.contains("\r") else { return .unknown }
        return ServerDeployment(rawValue: String(line.dropFirst("SG_STATUS_V1:".count))) ?? .unknown
    }
}

/// Fixed command; host/profile values are never inserted. Unknown must not authorize installation.
enum ServerDeploymentProbe {
    private static let script = """
        set -u
        if [ ! -r /etc/os-release ] || ! grep -Eq '^ID="?ubuntu"?$' /etc/os-release; then printf 'SG_STATUS_V1:unsupported\\n'; exit 0; fi
        for p in /opt/sovagrid-src /opt/sovagrid-agent /opt/sovagrid-vpn /opt/sovagrid-agent-installer /etc/sovagrid /etc/sovagrid-hub /etc/sovagrid-agent-tunnel /etc/sovagrid-agent-tunnel-public /var/lib/sovagrid /var/lib/sovagrid-agent /var/lib/sovagrid-agent-enrollment /var/lib/sovagrid-hub-tunnels /var/lib/sovagrid-first-install; do
          if [ -L "$p" ]; then printf 'SG_STATUS_V1:conflict\\n'; exit 0; fi
        done
        if [ -d /opt/sovagrid-src ] && [ "$(stat -c %u /opt/sovagrid-src 2>/dev/null)" = 0 ] &&
           [ -f /opt/sovagrid-src/sovagrid-bundle.json ] && [ ! -L /opt/sovagrid-src/sovagrid-bundle.json ] &&
           [ "$(stat -c %u /opt/sovagrid-src/sovagrid-bundle.json 2>/dev/null)" = 0 ] &&
           [ -f /var/lib/sovagrid/.managed-by-run-sh ] && [ ! -L /var/lib/sovagrid/.managed-by-run-sh ] &&
           [ "$(stat -c %u /var/lib/sovagrid/.managed-by-run-sh 2>/dev/null)" = 0 ]; then
           printf 'SG_STATUS_V1:managed\\n'; exit 0; fi
        if [ -f /opt/sovagrid-agent-installer/source-manifest.json ] &&
           [ -f /etc/systemd/system/sovagrid-agent.service ] &&
           [ -d /var/lib/sovagrid-agent-enrollment ] &&
           [ ! -e /opt/sovagrid-src ] && [ ! -e /etc/sovagrid-hub ] &&
           [ ! -e /var/lib/sovagrid ] && [ ! -e /etc/sovagrid/.agent-unit-managed-by-run-sh ]; then
           printf 'SG_STATUS_V1:agent_only\\n'; exit 0; fi
        for p in /opt/sovagrid-src /opt/sovagrid-agent /opt/sovagrid-vpn /opt/sovagrid-agent-installer /etc/sovagrid /etc/sovagrid-hub /etc/sovagrid-agent-tunnel /etc/sovagrid-agent-tunnel-public /var/lib/sovagrid /var/lib/sovagrid-agent /var/lib/sovagrid-agent-enrollment /var/lib/sovagrid-hub-tunnels /var/lib/sovagrid-first-install; do
           if [ -e "$p" ]; then printf 'SG_STATUS_V1:conflict\\n'; exit 0; fi
        done
        for base in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system; do
           for p in "$base"/sovagrid-*; do
              if [ -e "$p" ] || [ -L "$p" ]; then printf 'SG_STATUS_V1:conflict\\n'; exit 0; fi
           done
        done
        if command -v docker >/dev/null 2>&1; then
           if ! command -v timeout >/dev/null 2>&1; then printf 'SG_STATUS_V1:unknown\\n'; exit 0; fi
           projects=$(timeout 4 docker ps -a --filter label=com.docker.compose.project=sovagrid --format '{{.ID}}' 2>/dev/null) || { printf 'SG_STATUS_V1:unknown\\n'; exit 0; }
           if [ -n "$projects" ]; then printf 'SG_STATUS_V1:conflict\\n'; exit 0; fi
        fi
        printf 'SG_STATUS_V1:missing\\n'
        """

    static let command: String = {
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "if [ \"$(id -u)\" = 0 ]; then /bin/sh -c \(quoted); " +
            "elif command -v sudo >/dev/null 2>&1; then " +
            "sudo -n /bin/sh -c \(quoted) 2>/dev/null || printf 'SG_STATUS_V1:unknown\\n'; " +
            "else printf 'SG_STATUS_V1:unknown\\n'; fi"
    }()
}

/// A short-lived proof issued only through the selected server's authenticated SSH channel.
enum SSHGrantResponse {
    static let maximumOutputBytes = 512

    static let command = """
        if [ "$(id -u)" = 0 ]; then
          docker compose --env-file /etc/sovagrid/deploy.env -f /opt/sovagrid-src/sovagrid-blueprint/deploy/compose.yaml run --rm --no-deps -T --entrypoint python3 hub -m sovagrid_hub --db /data/hub.sqlite ssh-grant
        elif command -v sudo >/dev/null 2>&1; then
          sudo -n docker compose --env-file /etc/sovagrid/deploy.env -f /opt/sovagrid-src/sovagrid-blueprint/deploy/compose.yaml run --rm --no-deps -T --entrypoint python3 hub -m sovagrid_hub --db /data/hub.sqlite ssh-grant
        else exit 1; fi
        """

    static func parse(_ output: [UInt8], exitStatus: Int?) -> String? {
        guard exitStatus == 0, (2...maximumOutputBytes).contains(output.count),
              let text = String(bytes: output, encoding: .utf8) else { return nil }
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard !line.contains("\n"), !line.contains("\r"), !line.contains("\0"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["protocol", "grant", "expires_at", "username"]),
              let protocolNumber = object["protocol"] as? NSNumber,
              CFGetTypeID(protocolNumber) != CFBooleanGetTypeID(), protocolNumber.intValue == 1,
              let grant = object["grant"] as? String,
              grant.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let expiry = object["expires_at"] as? NSNumber,
              CFGetTypeID(expiry) != CFBooleanGetTypeID(),
              (1_000_000_000...4_102_444_800).contains(expiry.int64Value),
              let username = object["username"] as? String,
              !username.isEmpty, username.count <= 80,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return grant
    }

    static func javaScriptLiteral(_ grant: String) -> String? {
        guard grant.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let data = try? JSONSerialization.data(withJSONObject: grant, options: .fragmentsAllowed)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
