// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

enum SSHAuthKind: String, Codable, CaseIterable, Identifiable {
    case password = "Пароль"
    case ed25519 = "Ключ Ed25519"

    var id: String { rawValue }
}

struct SSHJumpHost: Codable, Equatable {
    var id: UUID
    var host: String
    var port: Int
    var username: String
    var auth: SSHAuthKind

    var address: String { "\(username)@\(host):\(port)" }
}

struct SSHServer: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var auth: SSHAuthKind
    var jump: SSHJumpHost?

    var address: String { "\(username)@\(host):\(port)" }
}

/// Selects the SSH server that owns the Hub loopback port. With no jump host,
/// both choices resolve to the only server in the profile.
enum PanelEndpoint {
    case entry
    case target

    func address(for server: SSHServer) -> String {
        if self == .entry, let jump = server.jump { return jump.address }
        return server.address
    }

    func usesNestedSSH(for server: SSHServer) -> Bool {
        self == .target && server.jump != nil
    }
}

struct HubMetric: Decodable {
    let collectedAt: Int64?
    let cpuPercent: Double?
    let memoryPercent: Double?
    let diskPercent: Double?
    let load1: Double?
    let uptimeSeconds: Double?
    let networkRxBytes: Double?
    let networkTxBytes: Double?
    let details: HubMetricDetails?

    enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at"
        case cpuPercent = "cpu_percent"
        case memoryPercent = "memory_percent"
        case diskPercent = "disk_percent"
        case load1
        case uptimeSeconds = "uptime_seconds"
        case networkRxBytes = "network_rx_bytes"
        case networkTxBytes = "network_tx_bytes"
        case details
    }
}

struct HubMetricDetails: Decodable {
    let clock: HubClockDetails?
    let containers: HubContainerInventory?
}

enum HubContainerID {
    static func valid(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        return bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Mirrors Hub's early protection filter. The Hub and Agent enforce their
    /// own policy independently; this only removes unsafe controls from UI.
    static func protected(name: String, image: String) -> Bool {
        guard !name.isEmpty, !image.isEmpty else { return true }
        func forbidden(_ part: String) -> Bool {
            let value = part.lowercased().drop(while: { $0 == "/" })
            return ["sovagrid", "amnezia", "docker", "containerd", "wireguard",
                    "openvpn", "tailscale", "xray", "sing-box", "ssh"]
                .contains(where: { value.hasPrefix($0) }) || value.contains("tunnel")
        }
        var parts = image.split(separator: "/").map(String.init)
        if parts.count > 1, let registry = parts.first,
           registry.contains(".") || registry.contains(":") || registry == "localhost" {
            parts.removeFirst()
        }
        return parts.isEmpty || forbidden(name) || parts.contains { part in
            let withoutTag = part.components(separatedBy: ":").first ?? ""
            let base = withoutTag.components(separatedBy: "@").first ?? ""
            return base.isEmpty || forbidden(base)
        }
    }
}

enum HubContainerAction: String, Codable, CaseIterable {
    case status, start, stop, restart

    var title: String {
        switch self {
        case .status: return "Проверить состояние"
        case .start: return "Запустить"
        case .stop: return "Остановить"
        case .restart: return "Перезапустить"
        }
    }

    var changesContainer: Bool { self != .status }
}

enum HubContainerState: String, Decodable {
    case created, running, paused, restarting, removing, exited, dead, unknown

    var title: String {
        switch self {
        case .created: return "Создан"
        case .running: return "Запущен"
        case .paused: return "Приостановлен"
        case .restarting: return "Перезапускается"
        case .removing: return "Удаляется"
        case .exited: return "Остановлен"
        case .dead: return "Недоступен"
        case .unknown: return "Неизвестно"
        }
    }
}

struct HubContainer: Decodable, Identifiable {
    let id: String
    let name: String
    let image: String
    let state: HubContainerState
    let health: String?
    let restarts: Int?
    let cpuPercent: Double?
    let memoryBytes: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, name, image, state, health, restarts
        case cpuPercent = "cpu_percent"
        case memoryBytes = "memory_bytes"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(String.self, forKey: .id)
        name = try value.decode(String.self, forKey: .name)
        image = try value.decode(String.self, forKey: .image)
        state = try value.decode(HubContainerState.self, forKey: .state)
        health = try value.decodeIfPresent(String.self, forKey: .health)
        restarts = try value.decodeIfPresent(Int.self, forKey: .restarts)
        cpuPercent = try value.decodeIfPresent(Double.self, forKey: .cpuPercent)
        memoryBytes = try value.decodeIfPresent(Int64.self, forKey: .memoryBytes)
        guard HubContainerID.valid(id), !name.isEmpty, !image.isEmpty,
              health == nil || ["starting", "healthy", "unhealthy"].contains(health!),
              restarts == nil || restarts! >= 0,
              cpuPercent == nil || (cpuPercent!.isFinite && (0...10000).contains(cpuPercent!)),
              memoryBytes == nil || memoryBytes! >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid container inventory item"))
        }
    }

    var isProtected: Bool { HubContainerID.protected(name: name, image: image) }
}

struct HubContainerEngine: Decodable {
    let engine: String
    let sourceStatus: String
    let reason: String?
    let truncated: Bool
    let containers: [HubContainer]

    private enum CodingKeys: String, CodingKey {
        case engine, reason, truncated, containers
        case sourceStatus = "source_status"
    }
}

struct HubContainerInventory: Decodable {
    let version: Int
    let collectedAt: Int64
    let engines: [HubContainerEngine]

    private enum CodingKeys: String, CodingKey {
        case version, engines
        case collectedAt = "collected_at"
    }

    var completeDocker: HubContainerEngine? {
        guard engines.count == 2, engines[0].engine == "docker",
              engines[1].engine == "podman", engines[0].sourceStatus == "ok",
              !engines[0].truncated else { return nil }
        return engines[0]
    }
}

struct HubContainerControl: Decodable {
    let sourceStatus: String
    let engine: String
    let id: String
    let observedAt: Int64?
    let state: HubContainerState?

    private enum CodingKeys: String, CodingKey {
        case engine, id, state
        case sourceStatus = "source_status"
        case observedAt = "observed_at"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        sourceStatus = try value.decode(String.self, forKey: .sourceStatus)
        engine = try value.decode(String.self, forKey: .engine)
        id = try value.decode(String.self, forKey: .id)
        observedAt = try value.decodeIfPresent(Int64.self, forKey: .observedAt)
        state = try value.decodeIfPresent(HubContainerState.self, forKey: .state)
        guard engine == "docker", HubContainerID.valid(id),
              (sourceStatus == "ok" && observedAt != nil && observedAt! > 0 && state != nil && state != .unknown) ||
              (sourceStatus == "unavailable" && observedAt == nil && state == nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid container control status"))
        }
    }
}

struct HubContainerMutationResult: Decodable {
    let action: HubContainerAction
    let id: String
    let result: String
    let state: HubContainerState?

    private enum CodingKeys: String, CodingKey { case action, id, result, state }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        action = try value.decode(HubContainerAction.self, forKey: .action)
        id = try value.decode(String.self, forKey: .id)
        result = try value.decode(String.self, forKey: .result)
        state = try value.decodeIfPresent(HubContainerState.self, forKey: .state)
        guard HubContainerID.valid(id), ["ok", "failed", "uncertain"].contains(result),
              state != .unknown,
              (result != "ok" || state != nil),
              (result != "ok" || action != .stop || state == .exited),
              (result != "ok" || ![HubContainerAction.start, .restart].contains(action) || state == .running) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid container action result"))
        }
    }
}

/// These values describe the Agent's clocks. RTC offset is RTC minus system
/// time; it is not a measurement of NTP accuracy.
struct HubClockDetails: Decodable {
    let systemUtcEpoch: Int64
    let timezone: String?
    let ntpSynchronized: Bool?
    let rtcLocalTime: Bool?
    let rtcUtcEpoch: Int64?
    let rtcOffsetSeconds: Int64?

    enum CodingKeys: String, CodingKey {
        case systemUtcEpoch = "system_utc_epoch"
        case timezone
        case ntpSynchronized = "ntp_synchronized"
        case rtcLocalTime = "rtc_local_time"
        case rtcUtcEpoch = "rtc_utc_epoch"
        case rtcOffsetSeconds = "rtc_offset_seconds"
    }
}

struct HubServer: Decodable, Identifiable {
    let id: String
    let name: String
    let latest: HubMetric?
    let online: Bool
    /// Older Hub versions omit this capability; never enable controls then.
    let remoteCommandsEnabled: Bool
    let lastSeen: Int64?
    /// Omitted by older Hub versions. A present but invalid role is rejected.
    let accessRole: HubRole?

    enum CodingKeys: String, CodingKey {
        case id, name, latest, online
        case remoteCommandsEnabled = "remote_commands_enabled"
        case lastSeen = "last_seen"
        case accessRole = "access_role"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(String.self, forKey: .id)
        name = try value.decode(String.self, forKey: .name)
        latest = try value.decodeIfPresent(HubMetric.self, forKey: .latest)
        online = try value.decode(Bool.self, forKey: .online)
        remoteCommandsEnabled = try value.decodeIfPresent(Bool.self, forKey: .remoteCommandsEnabled) ?? false
        lastSeen = try value.decodeIfPresent(Int64.self, forKey: .lastSeen)
        accessRole = value.contains(.accessRole) ? try value.decode(HubRole.self, forKey: .accessRole) : nil
    }
}

enum HubServiceAction: String, Codable, CaseIterable {
    case status, start, stop, restart

    var title: String {
        switch self {
        case .status: return "Проверить состояние"
        case .start: return "Запустить"
        case .stop: return "Остановить"
        case .restart: return "Перезапустить"
        }
    }

    var changesService: Bool { self != .status }
}

enum HubServiceUnit {
    private static let protectedBases: Set<String> = [
        "ssh", "sshd", "dropbear", "dbus", "networking", "networkmanager",
        "network-manager", "docker", "containerd", "podman", "cri-o",
        "nftables", "ufw", "firewalld", "iptables", "netfilter-persistent",
        "caddy", "wg-quick", "awg-quick", "openvpn", "strongswan", "ipsec"
    ]

    static func valid(_ unit: String) -> Bool {
        let bytes = Array(unit.utf8)
        let suffix = Array(".service".utf8)
        guard (suffix.count + 1...suffix.count + 88).contains(bytes.count),
              bytes.suffix(suffix.count).elementsEqual(suffix) else { return false }
        let stem = bytes.dropLast(suffix.count)
        guard let first = stem.first, isLetterOrDigit(first), stem.last != 64 else { return false }
        return stem.allSatisfy { isLetterOrDigit($0) || [95, 46, 64, 45].contains($0) }
    }

    static func protected(_ unit: String) -> Bool {
        guard valid(unit) else { return false }
        let stem = unit.dropLast(".service".count).lowercased()
        let base = String(stem.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0])
        return protectedBases.contains(base) ||
            ["sovagrid", "systemd-", "amnezia", "autossh"].contains { base.hasPrefix($0) } ||
            base.contains("tunnel")
    }

    static func validState(_ state: String) -> Bool {
        let bytes = Array(state.utf8)
        guard (1...32).contains(bytes.count), let first = bytes.first,
              (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }
}

struct HubServiceControl: Decodable {
    let sourceStatus: String
    let unit: String
    let observedAt: Int64?
    let loadState: String?
    let activeState: String?
    let subState: String?

    private enum CodingKeys: String, CodingKey {
        case sourceStatus = "source_status", unit
        case observedAt = "observed_at"
        case loadState = "load_state"
        case activeState = "active_state"
        case subState = "sub_state"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        sourceStatus = try value.decode(String.self, forKey: .sourceStatus)
        unit = try value.decode(String.self, forKey: .unit)
        observedAt = try value.decodeIfPresent(Int64.self, forKey: .observedAt)
        loadState = try value.decodeIfPresent(String.self, forKey: .loadState)
        activeState = try value.decodeIfPresent(String.self, forKey: .activeState)
        subState = try value.decodeIfPresent(String.self, forKey: .subState)
        guard HubServiceUnit.valid(unit), ["ok", "unavailable"].contains(sourceStatus) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid service control status"))
        }
        if sourceStatus == "ok" {
            guard let observedAt, observedAt > 0,
                  let loadState, HubServiceUnit.validState(loadState),
                  let activeState, HubServiceUnit.validState(activeState),
                  let subState, HubServiceUnit.validState(subState) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Invalid service state"))
            }
        } else if observedAt != nil || loadState != nil || activeState != nil || subState != nil {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unavailable service has state"))
        }
    }
}

struct HubServiceMutationResult: Decodable {
    let action: HubServiceAction
    let unit: String
    let result: String
    let loadState: String?
    let activeState: String?
    let subState: String?

    private enum CodingKeys: String, CodingKey {
        case action, unit, result
        case loadState = "load_state"
        case activeState = "active_state"
        case subState = "sub_state"
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        action = try value.decode(HubServiceAction.self, forKey: .action)
        unit = try value.decode(String.self, forKey: .unit)
        result = try value.decode(String.self, forKey: .result)
        loadState = try value.decodeIfPresent(String.self, forKey: .loadState)
        activeState = try value.decodeIfPresent(String.self, forKey: .activeState)
        subState = try value.decodeIfPresent(String.self, forKey: .subState)
        guard HubServiceUnit.valid(unit), ["ok", "failed", "uncertain"].contains(result),
              [loadState, activeState, subState].allSatisfy({ state in
                  guard let state else { return true }
                  return HubServiceUnit.validState(state)
              }),
              result != "ok" || [loadState, activeState, subState].allSatisfy({ $0 != nil }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid service action result"))
        }
    }
}

enum HubCheckKind: String, Decodable {
    case http, tcp, dns

    var title: String {
        switch self {
        case .http: return "HTTP/HTTPS"
        case .tcp: return "TCP"
        case .dns: return "DNS"
        }
    }
}

enum HubCheckState: String, Decodable {
    case disabled, waiting, up, down, stale

    var title: String {
        switch self {
        case .disabled: return "Выключена"
        case .waiting: return "Ожидает результат"
        case .up: return "Доступна"
        case .down: return "Недоступна"
        case .stale: return "Нет свежего результата"
        }
    }
}

enum HubCheckResultState: String, Decodable { case up, down }

struct HubCheckResult: Decodable {
    let observedAt: Int64
    let receivedAt: Int64
    let status: HubCheckResultState
    let latencyMs: Int
    let httpStatus: Int?
    let tlsExpiresAt: Int64?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case receivedAt = "received_at"
        case status
        case latencyMs = "latency_ms"
        case httpStatus = "http_status"
        case tlsExpiresAt = "tls_expires_at"
        case errorCode = "error_code"
    }

    var errorTitle: String? {
        switch errorCode {
        case "dns_error": return "Ошибка DNS"
        case "dns_mismatch": return "DNS вернул другой адрес"
        case "connect_error": return "Ошибка соединения"
        case "tls_error": return "Ошибка TLS"
        case "timeout": return "Таймаут"
        case "http_error": return "Ошибка HTTP"
        case "invalid_response": return "Неверный ответ"
        case "internal_error": return "Ошибка проверки"
        case nil: return nil
        default: return "Ошибка проверки"
        }
    }
}

struct HubCheckSummary: Decodable, Identifiable {
    let id: String
    let name: String
    let kind: HubCheckKind
    let enabled: Bool
    let intervalSeconds: Int
    let timeoutSeconds: Int
    let latest: HubCheckResult?
    let state: HubCheckState

    enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, latest, state
        case intervalSeconds = "interval_seconds"
        case timeoutSeconds = "timeout_seconds"
    }
}

struct HubChecksReply: Decodable {
    let serverId: String
    let revision: Int64
    let workerSeenAt: Int64?
    let checks: [HubCheckSummary]

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case revision
        case workerSeenAt = "worker_seen_at"
        case checks
    }
}

enum HubFilesystemAlertMetric: String, Codable, CaseIterable {
    case space, inodes

    var title: String { self == .space ? "Место" : "inode" }
}

enum HubFilesystemAlertSource: String, Decodable {
    case ok, stale, unavailable, partial

    var title: String {
        switch self {
        case .ok: return "Свежий список"
        case .stale: return "Данные устарели"
        case .unavailable: return "Данные недоступны"
        case .partial: return "Список неполный"
        }
    }
}

enum HubFilesystemAlertObservationStatus: String, Decodable {
    case normal, alert, unknown

    var title: String {
        switch self {
        case .normal: return "Ниже порога"
        case .alert: return "Порог достигнут"
        case .unknown: return "Нет подтверждения"
        }
    }
}

struct HubFilesystemAlertRule: Codable, Hashable {
    let mountpoint: String
    let metric: HubFilesystemAlertMetric
    var thresholdPercent: Int

    var key: String { mountpoint + "\u{0}" + metric.rawValue }
    var valid: Bool {
        mountpoint.hasPrefix("/") && mountpoint.utf8.count <= 128 &&
        !mountpoint.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        (1...100).contains(thresholdPercent)
    }

    enum CodingKeys: String, CodingKey {
        case mountpoint, metric
        case thresholdPercent = "threshold_percent"
    }
}

struct HubFilesystemAlertFilesystem: Decodable, Identifiable {
    let mountpoint: String
    let fstype: String
    let spaceUsedPercent: Double?
    let inodesUsedPercent: Double?

    var id: String { mountpoint }

    enum CodingKeys: String, CodingKey {
        case mountpoint, fstype
        case spaceUsedPercent = "space_used_percent"
        case inodesUsedPercent = "inodes_used_percent"
    }

    var valid: Bool {
        mountpoint.hasPrefix("/") && mountpoint.utf8.count <= 128 &&
        !fstype.isEmpty && fstype.utf8.count <= 32 &&
        [spaceUsedPercent, inodesUsedPercent].allSatisfy { percent in
            percent == nil || (percent!.isFinite && (0...100).contains(percent!))
        }
    }
}

struct HubFilesystemAlertObservation: Decodable {
    let mountpoint: String
    let metric: HubFilesystemAlertMetric
    let status: HubFilesystemAlertObservationStatus
    let usedPercent: Double?

    var key: String { mountpoint + "\u{0}" + metric.rawValue }

    enum CodingKeys: String, CodingKey {
        case mountpoint, metric, status
        case usedPercent = "used_percent"
    }
}

struct HubFilesystemAlertsReply: Decodable {
    let serverId: String
    let revision: Int
    let holdSeconds: Int
    let rules: [HubFilesystemAlertRule]
    let sourceStatus: HubFilesystemAlertSource
    let observedAt: Int64?
    let filesystems: [HubFilesystemAlertFilesystem]
    let observations: [HubFilesystemAlertObservation]

    enum CodingKeys: String, CodingKey {
        case revision, rules, filesystems, observations
        case serverId = "server_id"
        case holdSeconds = "hold_seconds"
        case sourceStatus = "source_status"
        case observedAt = "observed_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverId = try values.decode(String.self, forKey: .serverId)
        revision = try values.decode(Int.self, forKey: .revision)
        holdSeconds = try values.decode(Int.self, forKey: .holdSeconds)
        rules = try values.decode([HubFilesystemAlertRule].self, forKey: .rules)
        sourceStatus = try values.decode(HubFilesystemAlertSource.self, forKey: .sourceStatus)
        observedAt = try values.decodeIfPresent(Int64.self, forKey: .observedAt)
        filesystems = try values.decode([HubFilesystemAlertFilesystem].self, forKey: .filesystems)
        observations = try values.decode([HubFilesystemAlertObservation].self, forKey: .observations)
        let ruleKeys = rules.map(\.key), mountpoints = filesystems.map(\.mountpoint)
        guard (0..<Int.max).contains(revision), (0...86400).contains(holdSeconds),
              (sourceStatus != .ok || observedAt != nil), rules.count <= 32,
              rules.allSatisfy(\.valid), Set(ruleKeys).count == ruleKeys.count,
              filesystems.count <= 16, filesystems.allSatisfy(\.valid),
              Set(mountpoints).count == mountpoints.count,
              observations.count <= 32,
              observations.allSatisfy({ item in
                  item.mountpoint.hasPrefix("/") && item.mountpoint.utf8.count <= 128 &&
                  (item.usedPercent == nil || item.usedPercent!.isFinite &&
                   (0...100).contains(item.usedPercent!))
              }),
              Set(observations.map(\.key)).count == observations.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid filesystem alert state"))
        }
    }
}

struct HubFilesystemAlertUpdate: Encodable {
    let revision: Int
    let holdSeconds: Int
    let rules: [HubFilesystemAlertRule]

    enum CodingKeys: String, CodingKey {
        case revision, rules
        case holdSeconds = "hold_seconds"
    }
}

struct HubCheckHistoryReply: Decodable {
    let serverId: String
    let checkId: String
    let results: [HubCheckResult]

    enum CodingKeys: String, CodingKey {
        case serverId = "server_id"
        case checkId = "check_id"
        case results
    }
}

enum HubIncidentState: String, Decodable { case firing, resolved }

struct HubIncident: Decodable, Identifiable {
    let id: String
    let serverId: String
    let serverName: String
    let kind: String
    let state: HubIncidentState
    let openedAt: Int64
    let updatedAt: Int64
    let resolvedAt: Int64?
    let acknowledgedAt: Int64?
    let currentValue: Double?
    let threshold: Double?
    let alertedAt: Int64?
    let subject: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, state, subject
        case serverId = "server_id"
        case serverName = "server_name"
        case openedAt = "opened_at"
        case updatedAt = "updated_at"
        case resolvedAt = "resolved_at"
        case acknowledgedAt = "acknowledged_at"
        case currentValue = "current_value"
        case threshold
        case alertedAt = "alerted_at"
    }

    var title: String {
        if kind.hasPrefix("check:") { return subject ?? "Проверка доступности" }
        if kind.hasPrefix("tls:") { return "Срок сертификата: \(subject ?? "HTTPS-проверка")" }
        if kind.hasPrefix("container:") { return "Контейнер: \(subject ?? "Docker")" }
        if kind.hasPrefix("filesystem:space:") { return "Мало места: \(subject ?? "диск")" }
        if kind.hasPrefix("filesystem:inodes:") { return "Мало inode: \(subject ?? "диск")" }
        switch kind {
        case "high_cpu": return "Высокая загрузка CPU"
        case "high_memory": return "Высокое использование RAM"
        case "high_disk": return "Мало места на диске"
        case "high_root_inodes": return "Мало inode на корневом диске"
        case "failed_services": return "Ошибка службы"
        case "offline": return "Сервер офлайн"
        default: return "Инцидент"
        }
    }
}

enum HubTime {
    /// Hub timestamps are UTC Unix seconds; conversion happens only for UI.
    static func local(_ utcSeconds: Int64?, in zone: TimeZone = .current) -> String {
        guard let utcSeconds, (1...253_402_300_799).contains(utcSeconds) else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(utcSeconds)))) (\(zone.identifier))"
    }
}

enum HubRole: String, Decodable {
    case admin, `operator`, viewer

    var title: String {
        switch self {
        case .admin: return "Администратор"
        case .operator: return "Оператор"
        case .viewer: return "Наблюдатель"
        }
    }

    var rank: Int {
        switch self {
        case .viewer: return 1
        case .operator: return 2
        case .admin: return 3
        }
    }

    var canAcknowledge: Bool { rank >= HubRole.operator.rank }
}

enum HubAccessMode: String, Decodable { case all, selected }

struct HubSessionAccess: Decodable {
    let mode: HubAccessMode
    let revision: Int
    let unrestrictedAdmin: Bool

    private enum CodingKeys: String, CodingKey {
        case mode, revision
        case unrestrictedAdmin = "unrestricted_admin"
    }

    init(mode: HubAccessMode, revision: Int, unrestrictedAdmin: Bool) {
        self.mode = mode
        self.revision = revision
        self.unrestrictedAdmin = unrestrictedAdmin
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        mode = try value.decode(HubAccessMode.self, forKey: .mode)
        revision = try value.decode(Int.self, forKey: .revision)
        unrestrictedAdmin = try value.decode(Bool.self, forKey: .unrestrictedAdmin)
        guard revision >= 0, !(mode == .selected && unrestrictedAdmin) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid Hub server access"))
        }
    }

    func effectiveRole(for server: HubServer, globalRole: HubRole) -> HubRole? {
        if let role = server.accessRole {
            return role.rank <= globalRole.rank ? role : globalRole
        }
        return mode == .all ? globalRole : nil
    }
}

struct HubSessionAccessReply: Decodable { let access: HubSessionAccess }

struct HubIdentity: Decodable {
    let id: String?
    let username: String
    let role: HubRole
    let enabled: Bool

    private enum CodingKeys: String, CodingKey { case id, username, role, enabled }

    init(username: String) {
        id = nil
        self.username = username
        role = .admin
        enabled = true
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        let id = try value.decode(String.self, forKey: .id)
        let username = try value.decode(String.self, forKey: .username)
        let enabled = try value.decode(Bool.self, forKey: .enabled)
        guard !id.isEmpty, id.utf8.count <= 128,
              !username.isEmpty, username.utf8.count <= 320, enabled else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid or disabled Hub identity"))
        }
        self.id = id
        self.username = username
        self.enabled = enabled
        role = try value.decode(HubRole.self, forKey: .role)
    }

    func sessionBinding() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id.map { $0 as Any } ?? NSNull(),
            "username": username, "role": role.rawValue, "enabled": enabled], options: .sortedKeys)
    }
}

struct HubSessionReply: Decodable {
    let token: String?
    let user: HubIdentity?

    private enum CodingKeys: String, CodingKey { case token, user }

    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        token = try value.decodeIfPresent(String.self, forKey: .token)
        // Only omitted user metadata denotes the old single-admin Hub. A null
        // or malformed user object must never silently become administrator.
        user = value.contains(.user) ? try value.decode(HubIdentity.self, forKey: .user) : nil
    }

    func identity(fallbackUsername: String) -> HubIdentity {
        user ?? HubIdentity(username: fallbackUsername)
    }
}
