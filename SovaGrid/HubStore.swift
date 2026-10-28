// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation
import SwiftUI

private struct ServersReply: Decodable { let servers: [HubServer] }
private struct IncidentsReply: Decodable { let incidents: [HubIncident] }
private struct ServiceControlReply: Decodable { let control: HubServiceControl }
private struct ContainerControlReply: Decodable { let control: HubContainerControl }
private struct ServiceJobReply: Decodable { let job: ServiceJob }
private struct ServiceJob: Decodable {
    let id: String
    let state: String
    let exitCode: Int?
    let output: String?

    private enum CodingKeys: String, CodingKey {
        case id, state, output
        case exitCode = "exit_code"
    }
}

enum HubServiceError: LocalizedError {
    case unavailable, invalidUnit, invalidReply, statusRequired, statusFailed, rejected, uncertain

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Управление службой требует работающий Agent и права администратора на этот сервер."
        case .invalidUnit: return "Укажите полное имя службы, например nginx.service."
        case .invalidReply: return "Hub прислал неверный ответ о службе."
        case .statusRequired: return "Проверьте состояние службы ещё раз перед действием."
        case .statusFailed: return "Не удалось подтвердить состояние службы. Повторите проверку."
        case .rejected: return "Hub отклонил действие до постановки в очередь. Проверьте разрешения службы."
        case .uncertain: return "Действие могло выполниться. Сначала проверьте состояние службы снова."
        }
    }
}

enum HubContainerError: LocalizedError {
    case unavailable, invalidReply, statusRequired, statusFailed, rejected, uncertain

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Нужны права администратора, работающий Agent и полный свежий список Docker-контейнеров."
        case .invalidReply: return "Hub прислал неверный ответ о контейнере."
        case .statusRequired: return "Проверьте состояние контейнера ещё раз перед действием."
        case .statusFailed: return "Не удалось подтвердить состояние контейнера. Повторите проверку."
        case .rejected: return "Hub отклонил действие. Проверьте политику Agent для контейнера."
        case .uncertain: return "Действие могло выполниться. Сначала обновите список и проверьте контейнер снова."
        }
    }
}

enum HubFilesystemAlertError: LocalizedError {
    case unavailable, invalidReply, invalidRule, rejected, uncertain

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Войдите в Hub и выберите доступный сервер."
        case .invalidReply: return "Hub прислал неверные данные дисковых тревог."
        case .invalidRule: return "Проверьте точку монтирования, порог и задержку тревоги."
        case .rejected: return "Настройки изменились или действие отклонено. Обновите правила перед изменением."
        case .uncertain: return "Ответ о сохранении не подтверждён. Обновите правила, прежде чем менять их снова."
        }
    }
}

enum HubError: LocalizedError {
    case invalidURL
    case insecureURL
    case unauthorized
    case invalidSessionReply
    case identityChanged
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Укажите адрес Hub, например https://hub.example.com."
        case .insecureURL: return "Для удалённого Hub нужен HTTPS. HTTP разрешён только для localhost."
        case .unauthorized: return "Сессия истекла. Войдите снова."
        case .invalidSessionReply: return "Не удалось проверить учётную запись Hub. Войдите снова."
        case .identityChanged: return "Учётная запись или её права изменились. Войдите снова."
        case .server(let status, let message): return "Hub: HTTP \(status) — \(message)"
        }
    }
}

@MainActor
final class HubStore: ObservableObject {
    @Published var baseAddress: String = UserDefaults.standard.string(forKey: "sovagrid.hub.url") ?? ""
    @Published var username: String = UserDefaults.standard.string(forKey: "sovagrid.hub.user") ?? ""
    @Published private(set) var servers: [HubServer] = []
    @Published private(set) var checksByServer: [String: HubChecksReply] = [:]
    @Published private(set) var checkHistories: [String: HubCheckHistoryReply] = [:]
    @Published private(set) var historyLoading: Set<String> = []
    @Published private(set) var historyErrors: Set<String> = []
    @Published private(set) var checkErrors: Set<String> = []
    @Published private(set) var checksUnavailable: Set<String> = []
    @Published private(set) var firingIncidents: [HubIncident] = []
    @Published private(set) var resolvedIncidents: [HubIncident] = []
    @Published private(set) var incidentsProblem: String?
    @Published private(set) var identity: HubIdentity?
    @Published private(set) var access: HubSessionAccess?
    @Published private(set) var acknowledging: Set<String> = []
    @Published private(set) var loggedIn = KeychainStore.string(for: "hub.session") != nil
    @Published var busy = false
    @Published var errorMessage: String?
    private var authEpoch = UUID()
    private var activeRefreshEpoch: UUID?

    private let client: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private func url(_ path: String) throws -> URL {
        guard let base = URL(string: baseAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme?.lowercased(), let host = base.host, !host.isEmpty else {
            throw HubError.invalidURL
        }
        guard scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())) else {
            throw HubError.insecureURL
        }
        return base.appending(path: path)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HubError.server(0, "нет HTTP-ответа") }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw HubError.unauthorized }
            let body = String(data: data.prefix(512), encoding: .utf8) ?? "ошибка"
            throw HubError.server(http.statusCode, body)
        }
        return data
    }

    private func authorizedRequest(_ address: URL, token: String) -> URLRequest {
        var request = URLRequest(url: address)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func checks(for serverID: String, token: String) async throws -> HubChecksReply {
        let address = try url("api/v1/servers/\(serverID)/checks")
        return try JSONDecoder().decode(HubChecksReply.self,
                                        from: await send(authorizedRequest(address, token: token)))
    }

    private func filesystemAlertContext(serverID: String, admin: Bool) throws -> (String, UUID) {
        guard let token = KeychainStore.string(for: "hub.session"),
              let serverUUID = UUID(uuidString: serverID),
              serverUUID.uuidString.lowercased() == serverID.lowercased(),
              let server = servers.first(where: { $0.id == serverID }),
              let role = effectiveRole(for: server),
              (!admin || role == .admin) else { throw HubFilesystemAlertError.unavailable }
        return (token, authEpoch)
    }

    private func filesystemAlertContextStillValid(serverID: String, token: String,
                                                  epoch: UUID, admin: Bool) -> Bool {
        guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token,
              let server = servers.first(where: { $0.id == serverID }),
              let role = effectiveRole(for: server) else { return false }
        return !admin || role == .admin
    }

    func filesystemAlerts(serverID: String) async throws -> HubFilesystemAlertsReply {
        let (token, epoch) = try filesystemAlertContext(serverID: serverID, admin: false)
        do {
            let data = try await send(authorizedRequest(
                try url("api/v1/servers/\(serverID)/filesystems/alerts"), token: token))
            guard filesystemAlertContextStillValid(serverID: serverID, token: token,
                                                   epoch: epoch, admin: false),
                  let reply = try? JSONDecoder().decode(HubFilesystemAlertsReply.self, from: data),
                  reply.serverId == serverID else { throw HubFilesystemAlertError.invalidReply }
            return reply
        } catch {
            if invalidatesSession(error) { clearSession() }
            throw error
        }
    }

    func saveFilesystemAlerts(serverID: String, revision: Int, holdSeconds: Int,
                              rules: [HubFilesystemAlertRule]) async throws -> HubFilesystemAlertsReply {
        let (token, epoch) = try filesystemAlertContext(serverID: serverID, admin: true)
        let keys = rules.map(\.key)
        guard (0..<Int.max).contains(revision), (0...86400).contains(holdSeconds), rules.count <= 32,
              rules.allSatisfy(\.valid), Set(keys).count == keys.count else {
            throw HubFilesystemAlertError.invalidRule
        }
        var request = authorizedRequest(try url("api/v1/servers/\(serverID)/filesystems/alerts"), token: token)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(HubFilesystemAlertUpdate(
            revision: revision, holdSeconds: holdSeconds, rules: rules))
        let data: Data
        do { data = try await send(request) }
        catch {
            if invalidatesSession(error) { clearSession() }
            if case HubError.server(let status, _) = error,
               [400, 403, 404, 409, 422].contains(status) { throw HubFilesystemAlertError.rejected }
            throw HubFilesystemAlertError.uncertain
        }
        guard filesystemAlertContextStillValid(serverID: serverID, token: token,
                                               epoch: epoch, admin: true),
              let reply = try? JSONDecoder().decode(HubFilesystemAlertsReply.self, from: data),
              reply.serverId == serverID, reply.revision == revision + 1 else {
            throw HubFilesystemAlertError.uncertain
        }
        return reply
    }

    static func historyKey(serverID: String, checkID: String) -> String {
        "\(serverID)/\(checkID)"
    }

    func loadHistory(serverID: String, checkID: String) async {
        let key = Self.historyKey(serverID: serverID, checkID: checkID)
        guard let token = KeychainStore.string(for: "hub.session"),
              let summary = checksByServer[serverID],
              summary.checks.contains(where: { $0.id == checkID }),
              !historyLoading.contains(key) else { return }
        let epoch = authEpoch
        let revision = summary.revision
        historyLoading.insert(key)
        historyErrors.remove(key)
        defer {
            if authEpoch == epoch { historyLoading.remove(key) }
        }
        do {
            guard let serverUUID = UUID(uuidString: serverID),
                  let checkUUID = UUID(uuidString: checkID),
                  serverUUID.uuidString.lowercased() == serverID.lowercased(),
                  checkUUID.uuidString.lowercased() == checkID.lowercased() else {
                throw HubError.invalidSessionReply
            }
            let address = try url("api/v1/servers/\(serverID)/checks/\(checkID)/history")
                .appending(queryItems: [URLQueryItem(name: "limit", value: "60")])
            let reply = try JSONDecoder().decode(HubCheckHistoryReply.self,
                from: await send(authorizedRequest(address, token: token)))
            guard reply.serverId == serverID, reply.checkId == checkID,
                  reply.results.count <= 60 else { throw HubError.invalidSessionReply }
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token,
                  checksByServer[serverID]?.revision == revision,
                  checksByServer[serverID]?.checks.contains(where: { $0.id == checkID }) == true
            else { return }
            checkHistories[key] = reply
        } catch {
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            if invalidatesSession(error) {
                clearSession()
                errorMessage = error.localizedDescription
            } else {
                historyErrors.insert(key)
            }
        }
    }

    private func incidents(_ state: HubIncidentState, token: String) async throws -> [HubIncident] {
        let address = try url("api/v1/incidents")
            .appending(queryItems: [URLQueryItem(name: "state", value: state.rawValue)])
        let reply = try JSONDecoder().decode(IncidentsReply.self,
                                             from: await send(authorizedRequest(address, token: token)))
        return reply.incidents.filter { $0.state == state }
    }

    func effectiveRole(for server: HubServer) -> HubRole? {
        guard let identity, let access else { return nil }
        return access.effectiveRole(for: server, globalRole: identity.role)
    }

    func canAcknowledge(_ incident: HubIncident) -> Bool {
        guard incident.state == .firing, incident.acknowledgedAt == nil,
              let server = servers.first(where: { $0.id == incident.serverId }) else { return false }
        return effectiveRole(for: server)?.canAcknowledge == true
    }

    func acknowledge(_ incident: HubIncident) async {
        guard canAcknowledge(incident), !acknowledging.contains(incident.id),
              let token = KeychainStore.string(for: "hub.session") else { return }
        let epoch = authEpoch
        acknowledging.insert(incident.id)
        defer { if authEpoch == epoch { acknowledging.remove(incident.id) } }
        do {
            guard let incidentUUID = UUID(uuidString: incident.id),
                  incidentUUID.uuidString.lowercased() == incident.id.lowercased() else {
                throw HubError.invalidSessionReply
            }
            var request = authorizedRequest(try url("api/v1/incidents/\(incident.id)/ack"), token: token)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            _ = try await send(request)
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            await refresh()
        } catch {
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            if invalidatesSession(error) { clearSession() }
            errorMessage = error.localizedDescription
        }
    }

    private func serviceContext(serverID: String) throws -> (String, UUID) {
        guard let token = KeychainStore.string(for: "hub.session"),
              let canonicalID = UUID(uuidString: serverID),
              canonicalID.uuidString.lowercased() == serverID.lowercased(),
              let server = servers.first(where: { $0.id == serverID }),
              effectiveRole(for: server) == .admin,
              server.online, server.remoteCommandsEnabled else {
            throw HubServiceError.unavailable
        }
        return (token, authEpoch)
    }

    private func serviceContextStillValid(serverID: String, token: String, epoch: UUID) -> Bool {
        guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token,
              let server = servers.first(where: { $0.id == serverID }) else { return false }
        return effectiveRole(for: server) == .admin && server.online && server.remoteCommandsEnabled
    }

    private func serviceControl(serverID: String, unit: String, token: String,
                                epoch: UUID) async throws -> HubServiceControl {
        let address = try url("api/v1/servers/\(serverID)/services/control")
            .appending(queryItems: [URLQueryItem(name: "unit", value: unit)])
        let data = try await send(authorizedRequest(address, token: token))
        guard serviceContextStillValid(serverID: serverID, token: token, epoch: epoch),
              let control = try? JSONDecoder().decode(ServiceControlReply.self, from: data).control,
              control.unit == unit else { throw HubServiceError.invalidReply }
        return control
    }

    private func queueService(serverID: String, unit: String, action: HubServiceAction,
                              token: String, epoch: UUID) async throws -> String {
        var request = authorizedRequest(
            try url("api/v1/servers/\(serverID)/services/actions"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action.rawValue, "unit": unit])
        let data: Data
        do { data = try await send(request) }
        catch {
            if invalidatesSession(error) { clearSession() }
            if action.changesService {
                if case HubError.server(let status, _) = error,
                   [400, 403, 404, 409, 503].contains(status) { throw HubServiceError.rejected }
                throw HubServiceError.uncertain
            }
            throw error
        }
        guard serviceContextStillValid(serverID: serverID, token: token, epoch: epoch),
              let job = try? JSONDecoder().decode(ServiceJobReply.self, from: data).job,
              let jobID = UUID(uuidString: job.id),
              jobID.uuidString.lowercased() == job.id.lowercased() else {
            throw action.changesService ? HubServiceError.uncertain : HubServiceError.invalidReply
        }
        return job.id
    }

    private func waitServiceJob(_ jobID: String, serverID: String, token: String,
                                epoch: UUID, action: HubServiceAction) async throws -> ServiceJob {
        let deadline = ProcessInfo.processInfo.systemUptime + 75
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard serviceContextStillValid(serverID: serverID, token: token, epoch: epoch) else {
                throw action.changesService ? HubServiceError.uncertain : HubServiceError.unavailable
            }
            do {
                let data = try await send(authorizedRequest(
                    try url("api/v1/jobs/\(jobID)"), token: token))
                let job = try JSONDecoder().decode(ServiceJobReply.self, from: data).job
                guard job.id == jobID else { throw HubServiceError.invalidReply }
                if ["succeeded", "failed", "timed_out", "output_limited", "cancelled"].contains(job.state) {
                    return job
                }
                guard ["queued", "delivered"].contains(job.state) else { throw HubServiceError.invalidReply }
            } catch {
                if invalidatesSession(error) { clearSession() }
                throw action.changesService ? HubServiceError.uncertain : HubServiceError.statusFailed
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch {
                // Cancellation after Hub has accepted a mutation says nothing
                // about the service outcome. Never suggest an automatic retry.
                throw action.changesService ? HubServiceError.uncertain : HubServiceError.statusFailed
            }
        }
        throw action.changesService ? HubServiceError.uncertain : HubServiceError.statusFailed
    }

    func checkService(serverID: String, unit: String) async throws -> HubServiceControl {
        guard HubServiceUnit.valid(unit) else { throw HubServiceError.invalidUnit }
        let (token, epoch) = try serviceContext(serverID: serverID)
        let jobID = try await queueService(serverID: serverID, unit: unit,
                                           action: .status, token: token, epoch: epoch)
        let job = try await waitServiceJob(jobID, serverID: serverID, token: token,
                                           epoch: epoch, action: .status)
        guard job.state == "succeeded", job.exitCode == 0 else { throw HubServiceError.statusFailed }
        let control = try await serviceControl(serverID: serverID, unit: unit, token: token, epoch: epoch)
        guard control.sourceStatus == "ok" else { throw HubServiceError.statusFailed }
        return control
    }

    func changeService(serverID: String, unit: String,
                       action: HubServiceAction) async throws -> HubServiceMutationResult {
        guard action.changesService, HubServiceUnit.valid(unit) else { throw HubServiceError.invalidUnit }
        guard !HubServiceUnit.protected(unit) else { throw HubServiceError.rejected }
        let (token, epoch) = try serviceContext(serverID: serverID)
        let control = try await serviceControl(serverID: serverID, unit: unit, token: token, epoch: epoch)
        guard control.sourceStatus == "ok" else { throw HubServiceError.statusRequired }
        let jobID = try await queueService(serverID: serverID, unit: unit,
                                           action: action, token: token, epoch: epoch)
        let job = try await waitServiceJob(jobID, serverID: serverID, token: token,
                                           epoch: epoch, action: action)
        guard job.state == "succeeded", job.exitCode == 0,
              let output = job.output, let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(HubServiceMutationResult.self, from: data),
              result.action == action, result.unit == unit, result.result == "ok" else {
            throw HubServiceError.uncertain
        }
        return result
    }

    /// A new server reply is required for each action. Hub uses its own metric
    /// receipt time for the 120-second freshness limit, not the device clock.
    private func containerContext(serverID: String, containerID: String) async throws -> (String, UUID) {
        guard HubContainerID.valid(containerID),
              let serverUUID = UUID(uuidString: serverID),
              serverUUID.uuidString.lowercased() == serverID,
              let token = KeychainStore.string(for: "hub.session") else {
            throw HubContainerError.unavailable
        }
        let epoch = authEpoch
        let current = try await sessionIdentity(token: token)
        guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else {
            throw HubContainerError.unavailable
        }
        let binding = try current.sessionBinding()
        if let expected = KeychainStore.data(for: "hub.session.identity"), expected != binding {
            clearSession()
            throw HubError.identityChanged
        }
        let currentAccess = try await sessionAccess(token: token, identity: current)
        let data = try await send(authorizedRequest(try url("api/v1/servers"), token: token))
        guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else {
            throw HubContainerError.unavailable
        }
        let currentServers = try JSONDecoder().decode(ServersReply.self, from: data).servers
        identity = current
        access = currentAccess
        servers = currentServers
        guard let server = currentServers.first(where: { $0.id == serverID }),
              currentAccess.effectiveRole(for: server, globalRole: current.role) == .admin,
              server.online, server.remoteCommandsEnabled,
              let latest = server.latest,
              let inventory = latest.details?.containers,
              inventory.version == 1,
              let docker = inventory.completeDocker,
              docker.containers.contains(where: { $0.id == containerID && !$0.isProtected }) else {
            throw HubContainerError.unavailable
        }
        return (token, epoch)
    }

    private func containerContextStillValid(serverID: String, containerID: String,
                                            token: String, epoch: UUID) -> Bool {
        guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token,
              let server = servers.first(where: { $0.id == serverID }),
              effectiveRole(for: server) == .admin,
              server.online, server.remoteCommandsEnabled,
              let latest = server.latest,
              let inventory = latest.details?.containers,
              inventory.version == 1,
              let docker = inventory.completeDocker else { return false }
        return docker.containers.contains(where: { $0.id == containerID && !$0.isProtected })
    }

    private func containerControl(serverID: String, containerID: String, token: String,
                                  epoch: UUID) async throws -> HubContainerControl {
        let address = try url("api/v1/servers/\(serverID)/containers/control")
            .appending(queryItems: [URLQueryItem(name: "engine", value: "docker"),
                                    URLQueryItem(name: "id", value: containerID)])
        let data = try await send(authorizedRequest(address, token: token))
        guard containerContextStillValid(serverID: serverID, containerID: containerID,
                                         token: token, epoch: epoch),
              let control = try? JSONDecoder().decode(ContainerControlReply.self, from: data).control,
              control.id == containerID else { throw HubContainerError.invalidReply }
        return control
    }

    private func queueContainer(serverID: String, containerID: String, action: HubContainerAction,
                                token: String, epoch: UUID) async throws -> String {
        var request = authorizedRequest(try url("api/v1/servers/\(serverID)/containers/actions"), token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": action.rawValue, "engine": "docker", "id": containerID
        ])
        let data: Data
        do { data = try await send(request) }
        catch {
            if invalidatesSession(error) { clearSession() }
            if action.changesContainer {
                if case HubError.server(let status, _) = error,
                   [400, 403, 404, 409, 503].contains(status) { throw HubContainerError.rejected }
                throw HubContainerError.uncertain
            }
            throw error
        }
        guard containerContextStillValid(serverID: serverID, containerID: containerID,
                                         token: token, epoch: epoch),
              let job = try? JSONDecoder().decode(ServiceJobReply.self, from: data).job,
              let jobUUID = UUID(uuidString: job.id),
              jobUUID.uuidString.lowercased() == job.id else {
            throw action.changesContainer ? HubContainerError.uncertain : HubContainerError.invalidReply
        }
        return job.id
    }

    private func waitContainerJob(_ jobID: String, serverID: String, containerID: String,
                                  token: String, epoch: UUID,
                                  action: HubContainerAction) async throws -> ServiceJob {
        let deadline = ProcessInfo.processInfo.systemUptime + 75
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard containerContextStillValid(serverID: serverID, containerID: containerID,
                                             token: token, epoch: epoch) else {
                throw action.changesContainer ? HubContainerError.uncertain : HubContainerError.unavailable
            }
            do {
                let data = try await send(authorizedRequest(try url("api/v1/jobs/\(jobID)"), token: token))
                let job = try JSONDecoder().decode(ServiceJobReply.self, from: data).job
                guard job.id == jobID else { throw HubContainerError.invalidReply }
                if ["succeeded", "failed", "timed_out", "output_limited", "cancelled"].contains(job.state) {
                    return job
                }
                guard ["queued", "delivered"].contains(job.state) else { throw HubContainerError.invalidReply }
            } catch {
                if invalidatesSession(error) { clearSession() }
                throw action.changesContainer ? HubContainerError.uncertain : HubContainerError.statusFailed
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { throw action.changesContainer ? HubContainerError.uncertain : HubContainerError.statusFailed }
        }
        throw action.changesContainer ? HubContainerError.uncertain : HubContainerError.statusFailed
    }

    func checkContainer(serverID: String, containerID: String) async throws -> HubContainerControl {
        let (token, epoch) = try await containerContext(serverID: serverID, containerID: containerID)
        let jobID = try await queueContainer(serverID: serverID, containerID: containerID,
                                             action: .status, token: token, epoch: epoch)
        let job = try await waitContainerJob(jobID, serverID: serverID, containerID: containerID,
                                             token: token, epoch: epoch, action: .status)
        guard job.state == "succeeded", job.exitCode == 0 else { throw HubContainerError.statusFailed }
        let control = try await containerControl(serverID: serverID, containerID: containerID,
                                                 token: token, epoch: epoch)
        guard control.sourceStatus == "ok" else { throw HubContainerError.statusFailed }
        return control
    }

    func changeContainer(serverID: String, containerID: String,
                         action: HubContainerAction) async throws -> HubContainerMutationResult {
        guard action.changesContainer else { throw HubContainerError.rejected }
        let (token, epoch) = try await containerContext(serverID: serverID, containerID: containerID)
        let control = try await containerControl(serverID: serverID, containerID: containerID,
                                                 token: token, epoch: epoch)
        guard control.sourceStatus == "ok" else { throw HubContainerError.statusRequired }
        let jobID = try await queueContainer(serverID: serverID, containerID: containerID,
                                             action: action, token: token, epoch: epoch)
        let job = try await waitContainerJob(jobID, serverID: serverID, containerID: containerID,
                                             token: token, epoch: epoch, action: action)
        guard job.state == "succeeded", job.exitCode == 0,
              let output = job.output, let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(HubContainerMutationResult.self, from: data),
              result.action == action, result.id == containerID, result.result == "ok" else {
            throw HubContainerError.uncertain
        }
        return result
    }

    func login(password: String) async {
        let epoch = UUID()
        authEpoch = epoch
        let enteredUser = username
        let enteredAddress = baseAddress
        busy = true
        errorMessage = nil
        defer { if authEpoch == epoch { busy = false } }
        do {
            var request = URLRequest(url: try url("api/v1/session"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["username": enteredUser, "password": password])
            let reply = try decodeSession(await send(request))
            guard authEpoch == epoch else { return }
            guard username == enteredUser, baseAddress == enteredAddress else { throw HubError.invalidSessionReply }
            guard let token = reply.token, !token.isEmpty else { throw HubError.invalidSessionReply }
            let current = reply.identity(fallbackUsername: enteredUser)
            do {
                try KeychainStore.set(token, for: "hub.session")
                try KeychainStore.set(try current.sessionBinding(), for: "hub.session.identity")
            } catch {
                clearSession()
                errorMessage = error.localizedDescription
                return
            }
            UserDefaults.standard.set(enteredAddress, forKey: "sovagrid.hub.url")
            UserDefaults.standard.set(enteredUser, forKey: "sovagrid.hub.user")
            loggedIn = true
            identity = current
            await refresh()
        } catch {
            guard authEpoch == epoch else { return }
            if invalidatesSession(error) { clearSession() }
            if case HubError.unauthorized = error { errorMessage = "Неверный логин или пароль." }
            else { errorMessage = error.localizedDescription }
        }
    }

    func refresh() async {
        guard let token = KeychainStore.string(for: "hub.session") else {
            loggedIn = false
            identity = nil
            access = nil
            servers = []
            clearMonitoring()
            return
        }
        let epoch = authEpoch
        if activeRefreshEpoch == epoch { return }
        activeRefreshEpoch = epoch
        busy = true
        errorMessage = nil
        access = nil
        defer {
            if activeRefreshEpoch == epoch { activeRefreshEpoch = nil }
            if authEpoch == epoch { busy = false }
        }
        do {
            let current = try await sessionIdentity(token: token)
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            let binding = try current.sessionBinding()
            if let expected = KeychainStore.data(for: "hub.session.identity"), expected != binding {
                throw HubError.identityChanged
            }
            try KeychainStore.set(binding, for: "hub.session.identity")
            let currentAccess = try await sessionAccess(token: token, identity: current)
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            let request = authorizedRequest(try url("api/v1/servers"), token: token)
            let data = try await send(request)
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            let receivedServers = try JSONDecoder().decode(ServersReply.self, from: data).servers
            // Show current metrics while the independent check endpoints load.
            identity = current
            access = currentAccess
            servers = receivedServers
            var receivedFiring: [HubIncident] = []
            var receivedResolved: [HubIncident] = []
            var incidentFailure: String?
            do {
                receivedFiring = try await incidents(.firing, token: token)
                receivedResolved = try await incidents(.resolved, token: token)
            } catch HubError.server(let status, _) where status == 404 || status == 405 {
                incidentFailure = "Инциденты недоступны на этой версии Hub."
            } catch {
                if invalidatesSession(error) { throw error }
                incidentFailure = "Не удалось загрузить инциденты. Потяните вниз, чтобы повторить."
            }
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            firingIncidents = receivedFiring
            resolvedIncidents = receivedResolved
            incidentsProblem = incidentFailure
            var receivedChecks: [String: HubChecksReply] = [:]
            var receivedCheckErrors: Set<String> = []
            var unavailableChecks: Set<String> = []
            for server in receivedServers {
                do {
                    receivedChecks[server.id] = try await checks(for: server.id, token: token)
                } catch HubError.server(let status, _) where status == 404 || status == 405 {
                    unavailableChecks.insert(server.id)
                } catch {
                    if invalidatesSession(error) { throw error }
                    receivedCheckErrors.insert(server.id)
                }
            }
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            for (serverID, previous) in checksByServer {
                if receivedChecks[serverID]?.revision != previous.revision {
                    let prefix = serverID + "/"
                    checkHistories = checkHistories.filter { !$0.key.hasPrefix(prefix) }
                    historyErrors = Set(historyErrors.filter { !$0.hasPrefix(prefix) })
                }
            }
            checksByServer = receivedChecks
            checkErrors = receivedCheckErrors
            checksUnavailable = unavailableChecks
        } catch {
            guard authEpoch == epoch, KeychainStore.string(for: "hub.session") == token else { return }
            if invalidatesSession(error) { clearSession() }
            errorMessage = error.localizedDescription
        }
    }

    private func sessionIdentity(token: String) async throws -> HubIdentity {
        var request = URLRequest(url: try url("api/v1/session"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let reply = try decodeSession(await send(request))
            return reply.identity(fallbackUsername: username)
        } catch HubError.server(let status, _) where status == 404 || status == 405 {
            // Legacy Hub has a single administrator and no GET session route.
            return HubIdentity(username: username)
        }
    }

    private func sessionAccess(token: String, identity: HubIdentity) async throws -> HubSessionAccess {
        if identity.id == nil {
            return HubSessionAccess(mode: .all, revision: 0, unrestrictedAdmin: true)
        }
        do {
            let data = try await send(authorizedRequest(try url("api/v1/session/access"), token: token))
            let access: HubSessionAccess
            do { access = try JSONDecoder().decode(HubSessionAccessReply.self, from: data).access }
            catch { throw HubError.invalidSessionReply }
            guard !(identity.role != .admin && access.unrestrictedAdmin) else {
                throw HubError.invalidSessionReply
            }
            return access
        } catch HubError.server(let status, _) where status == 404 || status == 405 {
            // Legacy multi-user Hub has no server-specific policies.
            return HubSessionAccess(mode: .all, revision: 0,
                                    unrestrictedAdmin: identity.role == .admin)
        }
    }

    private func decodeSession(_ data: Data) throws -> HubSessionReply {
        do { return try JSONDecoder().decode(HubSessionReply.self, from: data) }
        catch { throw HubError.invalidSessionReply }
    }

    private func invalidatesSession(_ error: Error) -> Bool {
        switch error {
        case HubError.unauthorized, HubError.invalidSessionReply, HubError.identityChanged: return true
        default: return false
        }
    }

    private func clearSession() {
        authEpoch = UUID()
        activeRefreshEpoch = nil
        KeychainStore.remove("hub.session")
        KeychainStore.remove("hub.session.identity")
        identity = nil
        access = nil
        servers = []
        acknowledging = []
        clearMonitoring()
        loggedIn = false
        busy = false
        errorMessage = nil
    }

    private func clearMonitoring() {
        checksByServer = [:]
        checkHistories = [:]
        historyLoading = []
        historyErrors = []
        checkErrors = []
        checksUnavailable = []
        firingIncidents = []
        resolvedIncidents = []
        incidentsProblem = nil
    }

    func logout() async {
        var deletion: URLRequest?
        if let token = KeychainStore.string(for: "hub.session"), var request = try? URLRequest(url: url("api/v1/session")) {
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            deletion = request
        }
        clearSession()
        if let deletion { _ = try? await send(deletion) }
    }
}
