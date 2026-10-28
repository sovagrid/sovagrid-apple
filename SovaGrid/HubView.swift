// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import SwiftUI

struct HubView: View {
    @EnvironmentObject private var hub: HubStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var expandedHistories: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if hub.loggedIn {
                    serverList
                } else {
                    loginForm
                }
            }
            .navigationTitle("Мониторинг")
            .toolbar {
                if hub.loggedIn {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Выйти") { Task { await hub.logout() } }
                    }
                }
            }
            .alert("Ошибка Hub", isPresented: Binding(get: { hub.errorMessage != nil }, set: { if !$0 { hub.errorMessage = nil } })) {
                Button("ОК") { hub.errorMessage = nil }
            } message: {
                Text(hub.errorMessage ?? "")
            }
        }
        .onDisappear { password = "" }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { password = "" }
        }
        .onChange(of: hub.loggedIn) { _, loggedIn in
            if !loggedIn { expandedHistories = [] }
        }
    }

    private var loginForm: some View {
        Form {
            Section("SovaGrid Hub") {
                TextField("https://hub.example.com", text: $hub.baseAddress)
                    .serverTextInput()
                    .disabled(hub.busy)
                TextField("Логин", text: $hub.username)
                    .serverTextInput()
                    .disabled(hub.busy)
                SecureField("Пароль", text: $password)
                    .disabled(hub.busy)
                Button(hub.busy ? "Подключаемся…" : "Войти") {
                    let enteredPassword = password
                    password = ""
                    Task { await hub.login(password: enteredPassword) }
                }
                .disabled(hub.busy || password.isEmpty)
            }
            Section {
                Text("Для этой вкладки нужен HTTPS-адрес Hub. Полную панель без публичного HTTPS можно открыть через SSH на вкладке «Панель».")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serverList: some View {
        List {
            Section("Учётная запись") {
                if let identity = hub.identity {
                    LabeledContent("Пользователь", value: identity.username)
                    LabeledContent("Роль", value: identity.role.title)
                    if hub.access?.mode == .selected {
                        Text("Доступ ограничен выбранными серверами. Права для каждого показаны в его карточке.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Проверяем учётную запись…").foregroundStyle(.secondary)
                }
                Text("Время показано по часовому поясу устройства: \(TimeZone.current.identifier)")
                    .font(.caption).foregroundStyle(.secondary)
                if hub.busy { ProgressView("Обновляем мониторинг…") }
            }
            Section("Активные инциденты") {
                if let problem = hub.incidentsProblem {
                    Text(problem).foregroundStyle(.secondary)
                } else if hub.firingIncidents.isEmpty {
                    Label("Активных инцидентов нет", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hub.firingIncidents) { incident in incidentRow(incident) }
                }
            }
            if hub.servers.isEmpty && !hub.busy {
                ContentUnavailableView("Пока нет доступных серверов", systemImage: "chart.xyaxis.line",
                    description: Text(hub.access?.mode == .selected
                        ? "Администратор Hub ещё не назначил вам сервер."
                        : "Добавьте сервер и агент в Hub."))
            }
            ForEach(hub.servers) { server in
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        if let metric = server.latest {
                            HStack(spacing: 16) {
                                metricLabel("CPU", metric.cpuPercent)
                                metricLabel("RAM", metric.memoryPercent)
                                metricLabel("Диск", metric.diskPercent)
                            }
                            if let load = metric.load1 {
                                Text("Load 1m: \(load, specifier: "%.2f")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Метрика: \(HubTime.local(metric.collectedAt))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let clock = metric.details?.clock { clockDetails(clock) }
                        } else {
                            Text("Ожидаем первую метрику").font(.caption).foregroundStyle(.secondary)
                        }
                        if !server.online, let lastSeen = server.lastSeen {
                            Text("Последний контакт: \(HubTime.local(lastSeen))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 5)
                    checksSection(for: server)
                    NavigationLink {
                        HubFilesystemAlertsView(serverID: server.id, serverName: server.name)
                    } label: {
                        Label("Диски и тревоги", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("filesystem-alerts-\(server.id)")
                    if hub.effectiveRole(for: server) == .admin {
                        NavigationLink {
                            HubServiceControlView(serverID: server.id, serverName: server.name)
                        } label: {
                            Label("Службы systemd", systemImage: "gearshape.2")
                        }
                        .disabled(!server.online || !server.remoteCommandsEnabled)
                        NavigationLink {
                            HubContainersView(serverID: server.id, serverName: server.name)
                        } label: {
                            Label("Docker-контейнеры", systemImage: "shippingbox")
                        }
                        .accessibilityIdentifier("docker-containers-\(server.id)")
                        if !server.remoteCommandsEnabled {
                            Text("Команды для этого сервера выключены в Hub.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text(server.name).font(.headline)
                        Spacer()
                        if let role = hub.effectiveRole(for: server) {
                            Text(role.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Label(server.online ? "Онлайн" : "Офлайн", systemImage: server.online ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(server.online ? .green : .secondary)
                            .font(.caption)
                    }
                }
            }
            if !hub.resolvedIncidents.isEmpty {
                Section("Завершённые инциденты") {
                    ForEach(hub.resolvedIncidents) { incident in incidentRow(incident) }
                }
            }
        }
        .refreshable { await hub.refresh() }
        .task { await hub.refresh() }
    }

    @ViewBuilder
    private func checksSection(for server: HubServer) -> some View {
        if let summary = hub.checksByServer[server.id] {
            VStack(alignment: .leading, spacing: 5) {
                Text("Проверки доступности").font(.headline)
                if summary.checks.isEmpty {
                    Text("Проверки не настроены").foregroundStyle(.secondary)
                } else {
                    Text("Агент проверок: \(HubTime.local(summary.workerSeenAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(summary.checks) { check in checkRow(check, serverID: server.id) }
                }
            }
            .padding(.vertical, 5)
        } else if hub.checksUnavailable.contains(server.id) {
            Text("Проверки доступны после обновления Hub до 0.5.")
                .font(.caption).foregroundStyle(.secondary)
        } else if hub.checkErrors.contains(server.id) {
            Text("Не удалось загрузить проверки. Потяните вниз, чтобы повторить.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func checkRow(_ check: HubCheckSummary, serverID: String) -> some View {
        let key = HubStore.historyKey(serverID: serverID, checkID: check.id)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(check.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(check.state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(checkColor(check.state))
            }
            Text("\(check.kind.title) · каждые \(check.intervalSeconds) с")
                .font(.caption).foregroundStyle(.secondary)
            if let latest = check.latest {
                HStack(spacing: 10) {
                    Text("Последний ответ: \(latest.status == .up ? "доступна" : "недоступна")")
                    Text("\(latest.latencyMs) мс")
                    if let code = latest.httpStatus { Text("HTTP \(code)") }
                }
                .font(.caption)
                if let error = latest.errorTitle {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                Text("Проверено: \(HubTime.local(latest.observedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                if let expires = latest.tlsExpiresAt {
                    Text("Сертификат до: \(HubTime.local(expires))")
                        .font(.caption)
                        .foregroundStyle(expiresSoon(expires) ? .orange : .secondary)
                }
            }
            Button(expandedHistories.contains(key) ? "Скрыть историю" : "История запусков") {
                if expandedHistories.contains(key) {
                    expandedHistories.remove(key)
                } else {
                    expandedHistories.insert(key)
                    if hub.checkHistories[key] == nil {
                        Task { await hub.loadHistory(serverID: serverID, checkID: check.id) }
                    }
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .accessibilityLabel("История запусков: \(check.name)")
            if expandedHistories.contains(key) {
                if hub.historyLoading.contains(key) {
                    ProgressView("Загружаем историю…").font(.caption)
                } else if hub.historyErrors.contains(key) {
                    Button("Повторить загрузку истории") {
                        Task { await hub.loadHistory(serverID: serverID, checkID: check.id) }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                } else if let history = hub.checkHistories[key] {
                    Text("Запусков в истории: \(history.results.count)")
                        .font(.caption.weight(.semibold))
                    if history.results.isEmpty {
                        Text("Запусков ещё не было.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(history.results.enumerated()), id: \.offset) { _, result in
                        HStack(spacing: 8) {
                            Text(result.status == .up ? "Доступна" : "Недоступна")
                            Text(HubTime.local(result.observedAt))
                            Text("\(result.latencyMs) мс")
                            if let error = result.errorTitle { Text(error) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func incidentRow(_ incident: HubIncident) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(incident.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(incident.state == .firing ? "Активен" : "Завершён")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(incident.state == .firing ? .red : .green)
            }
            Text(incident.serverName).font(.caption).foregroundStyle(.secondary)
            if (incident.kind.hasPrefix("high_") || incident.kind.hasPrefix("filesystem:")),
               let value = incident.currentValue, let threshold = incident.threshold {
                Text(String(format: "Последнее значение %.1f%% · порог %.1f%%", value, threshold))
                    .font(.caption).foregroundStyle(.secondary)
            } else if incident.kind.hasPrefix("tls:"), let days = incident.currentValue,
                      let threshold = incident.threshold {
                Text(String(format: "До окончания %.0f дн. · предупреждение за %.0f дн.", days, threshold))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Начало: \(HubTime.local(incident.openedAt))")
                .font(.caption).foregroundStyle(.secondary)
            if let resolved = incident.resolvedAt {
                Text("Восстановлено: \(HubTime.local(resolved))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let acknowledged = incident.acknowledgedAt, incident.state == .firing {
                Text("Подтверждён: \(HubTime.local(acknowledged))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if hub.canAcknowledge(incident) {
                Button(hub.acknowledging.contains(incident.id) ? "Подтверждаем…" : "Подтвердить событие") {
                    Task { await hub.acknowledge(incident) }
                }
                .disabled(hub.acknowledging.contains(incident.id))
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
    }

    private func clockDetails(_ clock: HubClockDetails) -> some View {
        DisclosureGroup("Диагностика времени сервера") {
            VStack(alignment: .leading, spacing: 5) {
                Text("Системные часы: \(HubTime.local(clock.systemUtcEpoch))")
                Text("Часовой пояс сервера: \(clock.timezone ?? "неизвестен")")
                Text("Синхронизация NTP: \(ntpTitle(clock.ntpSynchronized))")
                Text("RTC хранит местное время: \(booleanTitle(clock.rtcLocalTime))")
                if let rtc = clock.rtcUtcEpoch {
                    Text("RTC: \(HubTime.local(rtc))")
                }
                if let offset = clock.rtcOffsetSeconds {
                    Text("RTC относительно системных часов: \(offset >= 0 ? "+" : "")\(offset) с")
                    Text("Разница RTC и системных часов не измеряет точность NTP.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private func ntpTitle(_ value: Bool?) -> String {
        switch value {
        case true: return "да"
        case false: return "нет"
        case nil: return "неизвестно"
        }
    }

    private func booleanTitle(_ value: Bool?) -> String {
        switch value {
        case true: return "да"
        case false: return "нет"
        case nil: return "неизвестно"
        }
    }

    private func checkColor(_ state: HubCheckState) -> Color {
        switch state {
        case .up: return .green
        case .down: return .red
        case .stale, .waiting: return .orange
        case .disabled: return .secondary
        }
    }

    private func expiresSoon(_ utcSeconds: Int64) -> Bool {
        TimeInterval(utcSeconds) <= Date().timeIntervalSince1970 + 14 * 24 * 60 * 60
    }

    private func metricLabel(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(.title3, design: .rounded).weight(.semibold))
        }
    }
}

private struct HubFilesystemAlertsView: View {
    @EnvironmentObject private var hub: HubStore
    let serverID: String
    let serverName: String

    @State private var snapshot: HubFilesystemAlertsReply?
    @State private var draftRules: [HubFilesystemAlertRule] = []
    @State private var holdText = "60"
    @State private var chosenMountpoint = ""
    @State private var chosenMetric: HubFilesystemAlertMetric = .space
    @State private var chosenThreshold = 90
    @State private var busy = false
    @State private var confirming = false
    @State private var error: String?
    @State private var message: String?
    @State private var viewEpoch = UUID()

    private var server: HubServer? { hub.servers.first(where: { $0.id == serverID }) }
    private var readable: Bool {
        guard hub.loggedIn, let server else { return false }
        return hub.effectiveRole(for: server) != nil
    }
    private var admin: Bool {
        guard hub.loggedIn, let server else { return false }
        return hub.effectiveRole(for: server) == .admin
    }
    private var available: [HubFilesystemAlertFilesystem] {
        snapshot?.sourceStatus == .ok ? snapshot?.filesystems ?? [] : []
    }
    private var selectedFilesystem: HubFilesystemAlertFilesystem? {
        available.first(where: { $0.mountpoint == chosenMountpoint })
    }
    private var canAdd: Bool {
        guard admin, !busy, draftRules.count < 32, let filesystem = selectedFilesystem else { return false }
        let percent = chosenMetric == .space ? filesystem.spaceUsedPercent : filesystem.inodesUsedPercent
        let key = HubFilesystemAlertRule(mountpoint: filesystem.mountpoint,
                                         metric: chosenMetric, thresholdPercent: chosenThreshold).key
        return percent != nil && !draftRules.contains(where: { $0.key == key })
    }
    private var changed: Bool {
        guard let snapshot else { return false }
        return draftRules != snapshot.rules || holdText != String(snapshot.holdSeconds)
    }

    var body: some View {
        Form {
            Section("Источник на \(serverName)") {
                if let snapshot {
                    LabeledContent("Состояние", value: snapshot.sourceStatus.title)
                    Text("Измерено: \(HubTime.local(snapshot.observedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    if snapshot.sourceStatus != .ok {
                        Text("Неполный или устаревший список не подтверждает восстановление. Новую точку монтирования можно выбрать после свежего полного снимка.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if busy {
                    ProgressView("Загружаем диски…")
                } else {
                    Text("Нажмите «Обновить», чтобы получить состояние.")
                        .foregroundStyle(.secondary)
                }
                Button("Обновить") { Task { await load() } }
                    .disabled(busy || !readable)
            }
            if let snapshot {
                Section("Измерения") {
                    if snapshot.filesystems.isEmpty {
                        Text("Свежий полный список дисков пока недоступен.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.filesystems) { filesystem in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(filesystem.mountpoint).font(.subheadline.weight(.semibold))
                                Text("\(filesystem.fstype) · место \(percentage(filesystem.spaceUsedPercent)) · inode \(percentage(filesystem.inodesUsedPercent))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Section("Правила") {
                    if draftRules.isEmpty {
                        Text("Оповещения выключены.").foregroundStyle(.secondary)
                    }
                    ForEach(draftRules, id: \.key) { rule in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(rule.mountpoint).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(rule.metric.title).font(.caption).foregroundStyle(.secondary)
                            }
                            if let observation = snapshot.observations.first(where: { $0.key == rule.key }) {
                                Text("\(observation.status.title) · сейчас \(percentage(observation.usedPercent))")
                                    .font(.caption)
                                    .foregroundColor(observation.status == .alert ? .red : .secondary)
                            }
                            if admin {
                                Stepper("Порог: \(rule.thresholdPercent)%", value: Binding(
                                    get: { draftRules.first(where: { $0.key == rule.key })?.thresholdPercent ?? rule.thresholdPercent },
                                    set: { value in
                                        if let index = draftRules.firstIndex(where: { $0.key == rule.key }) {
                                            draftRules[index].thresholdPercent = value
                                        }
                                    }), in: 1...100)
                                Button("Удалить правило", role: .destructive) {
                                    draftRules.removeAll(where: { $0.key == rule.key })
                                }
                                .disabled(busy)
                            } else {
                                Text("Порог: \(rule.thresholdPercent)%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                if admin {
                    Section("Добавить правило") {
                        if available.isEmpty {
                            Text("Дождитесь свежего полного списка файловых систем.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("Точка монтирования", selection: $chosenMountpoint) {
                                ForEach(available) { filesystem in
                                    Text(filesystem.mountpoint).tag(filesystem.mountpoint)
                                }
                            }
                            Picker("Что контролировать", selection: $chosenMetric) {
                                ForEach(HubFilesystemAlertMetric.allCases, id: \.self) { metric in
                                    Text(metric.title).tag(metric)
                                }
                            }
                            Stepper("Порог: \(chosenThreshold)%", value: $chosenThreshold, in: 1...100)
                            Button("Добавить") { addRule() }.disabled(!canAdd)
                            if selectedFilesystem != nil && !canAdd {
                                Text("Для этой пары нужна доступная метрика и отсутствие другого правила с тем же диском и типом.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Сохранение") {
                        TextField("Задержка тревоги, секунд", text: $holdText)
                            .disabled(busy)
                        Text("От 0 до 86400 секунд. Изменение правил защищено ревизией; при неопределённом ответе сначала обновите состояние.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(busy ? "Сохраняем…" : "Проверить и сохранить") { prepareSave() }
                            .disabled(busy || !changed)
                    }
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Диски и тревоги")
        .refreshable { await load() }
        .task { await load() }
        .alert("Сохранить дисковые тревоги?", isPresented: $confirming) {
            Button("Сохранить") { save() }
            Button("Отмена", role: .cancel) { confirming = false }
        } message: {
            Text("Сервер: \(serverName). Правил: \(draftRules.count). Задержка: \(holdText) с. Новые пороги могут вызвать уведомление после подтверждённых метрик.")
        }
        .onChange(of: hub.loggedIn) { _, loggedIn in if !loggedIn { reset() } }
        .onChange(of: admin) { _, allowed in if !allowed { confirming = false } }
        .onDisappear { reset() }
    }

    private func percentage(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "—"
    }

    private func reset() {
        viewEpoch = UUID()
        busy = false
        snapshot = nil
        draftRules = []
        confirming = false
        error = nil
        message = nil
    }

    private func load() async {
        guard !busy, readable else { return }
        let epoch = viewEpoch
        busy = true
        error = nil
        message = nil
        defer { if viewEpoch == epoch { busy = false } }
        do {
            let result = try await hub.filesystemAlerts(serverID: serverID)
            guard viewEpoch == epoch, readable else { return }
            snapshot = result
            draftRules = result.rules
            holdText = String(result.holdSeconds)
            if !result.filesystems.contains(where: { $0.mountpoint == chosenMountpoint }) {
                chosenMountpoint = result.filesystems.first?.mountpoint ?? ""
            }
        } catch HubError.server(let status, _) where status == 404 || status == 405 {
            guard viewEpoch == epoch else { return }
            snapshot = nil
            error = "Обновите Hub, чтобы пользоваться дисковыми тревогами."
        } catch let failure {
            guard viewEpoch == epoch else { return }
            snapshot = nil
            error = failure.localizedDescription
        }
    }

    private func addRule() {
        guard canAdd, let filesystem = selectedFilesystem else { return }
        draftRules.append(HubFilesystemAlertRule(mountpoint: filesystem.mountpoint,
                                                 metric: chosenMetric, thresholdPercent: chosenThreshold))
        message = "Правило добавлено в черновик. Сохраните изменения."
    }

    private func prepareSave() {
        guard admin, !busy, changed, snapshot != nil else { return }
        guard let hold = Int(holdText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...86400).contains(hold), draftRules.count <= 32,
              draftRules.allSatisfy(\.valid) else {
            error = "Укажите задержку от 0 до 86400 секунд и пороги от 1 до 100%."
            return
        }
        error = nil
        confirming = true
    }

    private func save() {
        confirming = false
        guard admin, !busy, changed, let snapshot,
              let hold = Int(holdText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...86400).contains(hold) else { return }
        let epoch = viewEpoch
        let rules = draftRules
        let revision = snapshot.revision
        busy = true
        error = nil
        message = nil
        Task {
            defer { if viewEpoch == epoch { busy = false } }
            do {
                let result = try await hub.saveFilesystemAlerts(serverID: serverID,
                    revision: revision, holdSeconds: hold, rules: rules)
                guard viewEpoch == epoch, readable else { return }
                self.snapshot = result
                draftRules = result.rules
                holdText = String(result.holdSeconds)
                message = "Правила сохранены и подтверждены Hub."
            } catch {
                guard viewEpoch == epoch else { return }
                // A lost reply might follow a committed PUT. Require an
                // explicit GET before another mutation; never replay it.
                self.snapshot = nil
                self.error = error.localizedDescription
            }
        }
    }
}

private struct HubContainersView: View {
    @EnvironmentObject private var hub: HubStore
    let serverID: String
    let serverName: String

    private var server: HubServer? { hub.servers.first(where: { $0.id == serverID }) }
    private var inventory: HubContainerInventory? { server?.latest?.details?.containers }
    private var docker: HubContainerEngine? { inventory?.engines.first(where: { $0.engine == "docker" }) }
    private var complete: Bool {
        guard let server, let inventory else { return false }
        return server.online && inventory.version == 1 && inventory.completeDocker != nil
    }

    var body: some View {
        List {
            Section("Docker на \(serverName)") {
                if let inventory {
                    Text("Снимок: \(HubTime.local(inventory.collectedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if complete, let docker {
                    if docker.containers.isEmpty {
                        Text("Контейнеров нет").foregroundStyle(.secondary)
                    }
                    ForEach(docker.containers) { container in
                        if container.isProtected {
                            containerSummary(container)
                            Text("Системный контейнер: управление скрыто.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            NavigationLink {
                                HubContainerDetailView(serverID: serverID, serverName: serverName,
                                                       containerID: container.id)
                            } label: {
                                containerSummary(container)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Полный список Docker пока недоступен", systemImage: "shippingbox",
                        description: Text("Обновите мониторинг. Для действий нужен свежий полный снимок работающего Agent."))
                }
            }
            Section {
                Text("Показываются точные контейнеры из инвентаря Agent. Поддерживается Docker; Podman и усечённый список доступны только для просмотра в полной панели.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Контейнеры")
        .refreshable { await hub.refresh() }
    }

    private func containerSummary(_ container: HubContainer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(container.name).font(.headline)
            Text("\(container.state.title) · \(container.image)")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
            Text("ID: \(container.id)")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }
}

private struct HubContainerDetailView: View {
    @EnvironmentObject private var hub: HubStore
    let serverID: String
    let serverName: String
    let containerID: String

    @State private var control: HubContainerControl?
    @State private var checkedAtUptime: TimeInterval?
    @State private var confirmation: HubContainerAction?
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    private var server: HubServer? { hub.servers.first(where: { $0.id == serverID }) }
    private var container: HubContainer? {
        guard let latest = server?.latest, let inventory = latest.details?.containers,
              inventory.version == 1,
              let docker = inventory.completeDocker else { return nil }
        return docker.containers.first(where: { $0.id == containerID })
    }
    private var permitted: Bool {
        guard let server, server.online, server.remoteCommandsEnabled,
              hub.effectiveRole(for: server) == .admin,
              let container, !container.isProtected else { return false }
        return hub.loggedIn
    }
    private var fresh: Bool {
        guard permitted, let control, let checkedAtUptime,
              control.sourceStatus == "ok", control.id == containerID else { return false }
        return ProcessInfo.processInfo.systemUptime - checkedAtUptime < 45
    }

    var body: some View {
        Form {
            Section("Контейнер на \(serverName)") {
                if let container {
                    LabeledContent("Имя", value: container.name)
                    LabeledContent("Образ", value: container.image)
                    LabeledContent("По инвентарю", value: container.state.title)
                } else {
                    Text("Контейнер отсутствует в полном снимке Docker. Обновите список.")
                        .foregroundStyle(.secondary)
                }
                Text("ID: \(containerID)").font(.caption2.monospaced())
                    .textSelection(.enabled)
                Button(busy ? "Ожидаем Hub…" : "Проверить состояние") { check() }
                    .disabled(busy || !permitted)
            }
            Section("Проверенное состояние") {
                if let control, control.sourceStatus == "ok" {
                    LabeledContent("Состояние", value: control.state?.title ?? "—")
                    Text("Проверено: \(HubTime.local(control.observedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Сначала проверьте контейнер.").foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Действия") {
                ForEach([HubContainerAction.start, .stop, .restart], id: \.self) { action in
                    Button(action.title) { prepare(action) }
                        .disabled(busy || !fresh)
                }
                Text("Перед действием нужен успешный status. После действия или неопределённого ответа обновите список и проверьте состояние снова.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Docker")
        .alert("Подтвердить действие", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        )) {
            if let action = confirmation {
                Button(action.title, role: .destructive) { confirm(action) }
            }
            Button("Отмена", role: .cancel) { confirmation = nil }
        } message: {
            Text("\(confirmation?.title ?? "Действие") контейнер \(container?.name ?? containerID) на \(serverName)? Локальная политика Agent должна разрешать это действие.")
        }
        .onChange(of: hub.loggedIn) { _, loggedIn in if !loggedIn { invalidateCheck() } }
        .onChange(of: permitted) { _, allowed in if !allowed { invalidateCheck() } }
    }

    private func invalidateCheck() {
        control = nil
        checkedAtUptime = nil
        confirmation = nil
    }

    private func check() {
        guard !busy, permitted else { return }
        invalidateCheck()
        message = nil
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let latest = try await hub.checkContainer(serverID: serverID, containerID: containerID)
                guard permitted else { return }
                control = latest
                checkedAtUptime = ProcessInfo.processInfo.systemUptime
                message = "Состояние подтверждено. Выберите действие."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func prepare(_ action: HubContainerAction) {
        guard action.changesContainer, !busy, fresh else {
            error = "Проверьте контейнер и права ещё раз."
            return
        }
        error = nil
        confirmation = action
    }

    private func confirm(_ action: HubContainerAction) {
        confirmation = nil
        guard !busy, fresh else {
            error = "Состояние изменилось. Проверьте контейнер снова."
            return
        }
        invalidateCheck()
        message = nil
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await hub.changeContainer(serverID: serverID, containerID: containerID,
                                                           action: action)
                guard permitted else { return }
                message = "\(action.title): \(result.state?.title ?? "состояние неизвестно"). Обновите список перед следующим действием."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct HubServiceControlView: View {
    @EnvironmentObject private var hub: HubStore
    let serverID: String
    let serverName: String

    @State private var unit = ""
    @State private var control: HubServiceControl?
    @State private var checkedAtUptime: TimeInterval?
    @State private var confirmation: HubServiceAction?
    @State private var busy = false
    @State private var message: String?
    @State private var error: String?

    private var selectedUnit: String { unit.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var protected: Bool { HubServiceUnit.protected(selectedUnit) }
    private var permitted: Bool {
        guard hub.loggedIn, let server = hub.servers.first(where: { $0.id == serverID }) else { return false }
        return hub.effectiveRole(for: server) == .admin && server.online && server.remoteCommandsEnabled
    }
    private var fresh: Bool {
        guard let control, let checkedAtUptime, control.sourceStatus == "ok",
              control.unit == selectedUnit else { return false }
        return ProcessInfo.processInfo.systemUptime - checkedAtUptime < 45
    }

    var body: some View {
        Form {
            Section("Служба на \(serverName)") {
                TextField("nginx.service", text: $unit)
                    .serverTextInput()
                    .disabled(busy)
                Button(busy ? "Ожидаем Hub…" : "Проверить состояние") { check() }
                    .disabled(busy || !permitted || !HubServiceUnit.valid(selectedUnit))
                Text("Укажите полное имя .service. Сначала получите состояние, затем подтвердите действие.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Состояние") {
                if let control, control.sourceStatus == "ok" {
                    LabeledContent("Загрузка", value: control.loadState ?? "—")
                    LabeledContent("Активность", value: control.activeState ?? "—")
                    LabeledContent("Подсостояние", value: control.subState ?? "—")
                    Text("Проверено: \(HubTime.local(control.observedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Служба ещё не проверена.").foregroundStyle(.secondary)
                }
                if protected {
                    Text("Эта служба связана с доступом к хосту, сетью или SovaGrid. Здесь доступна только проверка состояния.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Действия") {
                ForEach([HubServiceAction.start, .stop, .restart], id: \.self) { action in
                    Button(action.title) { prepare(action) }
                        .disabled(busy || !permitted || !fresh || protected)
                }
                Text("Состояние должно быть проверено недавно. После любого действия, особенно при тайм-ауте, проверьте его снова перед повтором.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Службы")
        .alert("Подтвердить действие", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        )) {
            if let action = confirmation {
                Button(action.title, role: .destructive) { confirm(action) }
            }
            Button("Отмена", role: .cancel) { confirmation = nil }
        } message: {
            Text("\(confirmation?.title ?? "Действие") \(selectedUnit) на \(serverName)? Управление должно быть разрешено в локальной политике Agent.")
        }
        .onChange(of: unit) { _, _ in invalidateCheck() }
        .onChange(of: hub.loggedIn) { _, loggedIn in if !loggedIn { invalidateCheck() } }
    }

    private func invalidateCheck() {
        control = nil
        checkedAtUptime = nil
        confirmation = nil
    }

    private func check() {
        let target = selectedUnit
        guard !busy, permitted, HubServiceUnit.valid(target) else { return }
        invalidateCheck()
        message = nil
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let latest = try await hub.checkService(serverID: serverID, unit: target)
                guard selectedUnit == target, permitted else { return }
                control = latest
                checkedAtUptime = ProcessInfo.processInfo.systemUptime
                message = "Состояние подтверждено. Для изменения выберите действие."
            } catch {
                guard selectedUnit == target else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func prepare(_ action: HubServiceAction) {
        guard action.changesService, !busy, permitted, fresh, !protected else {
            error = "Проверьте состояние и разрешения службы ещё раз."
            return
        }
        error = nil
        confirmation = action
    }

    private func confirm(_ action: HubServiceAction) {
        confirmation = nil
        let target = selectedUnit
        guard !busy, permitted, fresh, !HubServiceUnit.protected(target) else {
            error = "Состояние изменилось. Проверьте службу снова."
            return
        }
        invalidateCheck()
        message = nil
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await hub.changeService(serverID: serverID, unit: target, action: action)
                guard selectedUnit == target, permitted else { return }
                message = "\(action.title): \(result.activeState ?? "состояние неизвестно"). Проверьте службу снова перед следующим действием."
            } catch {
                guard selectedUnit == target else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
