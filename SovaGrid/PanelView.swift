// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import SwiftUI
import WebKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import Darwin
#endif

struct PanelView: View {
    @EnvironmentObject private var servers: ServerStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var tunnel = PanelTunnel()
    @State private var panelWebView: WKWebView?

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Панель")
            .alert("Новый ключ сервера", isPresented: Binding(get: { tunnel.hostChallenge != nil }, set: { _ in })) {
                Button("Доверять") { tunnel.acceptHostKey(true) }
                Button("Отмена", role: .cancel) { tunnel.acceptHostKey(false) }
            } message: {
                Text("\(tunnel.hostChallenge?.address ?? "")\nSHA256:\(tunnel.hostChallenge?.fingerprint ?? "")\nСверьте отпечаток сервера перед подтверждением.")
            }
            .alert("Ошибка SSH-панели", isPresented: Binding(get: { tunnel.errorMessage != nil }, set: { if !$0 { tunnel.errorMessage = nil } })) {
                Button("ОК") { tunnel.errorMessage = nil }
            } message: {
                Text(tunnel.errorMessage ?? "")
            }
            .alert("Пароль недоступен", isPresented: Binding(get: { tunnel.bootstrapError != nil }, set: { if !$0 { tunnel.bootstrapError = nil } })) {
                Button("ОК") { tunnel.bootstrapError = nil }
            } message: {
                Text(tunnel.bootstrapError ?? "")
            }
            .alert("Состояние сервера", isPresented: Binding(get: { tunnel.deploymentNotice != nil }, set: { if !$0 { tunnel.deploymentNotice = nil } })) {
                if tunnel.deploymentNotice == .missing {
                    if tunnel.canInstallHub {
                        Button("Установить") {
                            tunnel.deploymentNotice = nil
                            tunnel.installHub()
                        }
                    }
                    Button("Открыть Starter") {
                        tunnel.deploymentNotice = nil
                        stopPanel()
                        if let url = URL(string: "https://github.com/sovagrid/sovagrid-blueprint/releases/tag/server-v0.14.1") {
                            openURL(url)
                        }
                    }
                }
                Button("Закрыть", role: .cancel) {
                    tunnel.deploymentNotice = nil
                    if tunnel.canInstallHub { stopPanel() }
                }
            } message: {
                Text(deploymentMessage(tunnel.deploymentNotice))
            }
            .sheet(isPresented: Binding(get: { tunnel.bootstrapPassword != nil }, set: { if !$0 { tunnel.clearBootstrapPassword() } })) {
                BootstrapPasswordSheet(tunnel: tunnel)
            }
        }
        .onDisappear { stopPanel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stopPanel() }
        }
        .onChange(of: tunnel.localURL) { oldURL, newURL in
            if oldURL != newURL { panelWebView = nil }
            if oldURL != nil && newURL == nil { BootstrapPasswordClipboard.clearIfUnchanged() }
        }
        .onChange(of: tunnel.routeRevision) { _, _ in panelWebView = nil }
    }

    private func stopPanel() {
        BootstrapPasswordClipboard.clearIfUnchanged()
        panelWebView = nil
        tunnel.stop()
    }

    private func deploymentMessage(_ state: ServerDeployment?) -> String {
        switch state {
        case .missing:
            if tunnel.canInstallHub {
                return "Установить SovaGrid \(SovaGridFirstInstall.version) на выбранный Ubuntu-сервер? Сервер загрузит официальный пакет, сверит SHA-256 и повторно проверит, что SovaGrid ещё не установлен. Затем настроит Docker, локальные Hub и Agent, терминал, файлы, мониторинг контейнеров и управление WireGuard. VPN-интерфейс включается отдельно в панели. После проверки панель откроется здесь."
            }
            return "Для первой установки нужны root или права sudo без запроса пароля. Пароль SSH не заменяет разрешение sudo. На компьютере также можно использовать SovaGrid Starter."
        case .agentOnly:
            return "Здесь работает только Agent. Полная установка поверх него могла бы затронуть туннель и ключи. Для другого сервера выберите Hub на промежуточном узле; перенос на самостоятельный Hub будет отдельной безопасной операцией."
        case .conflict:
            return "На сервере заняты файлы или службы SovaGrid, но управляемый Hub не подтверждён. Проверьте состояние в SovaGrid Connect."
        case .unsupported:
            return "Серверная часть сейчас поддерживается на Ubuntu. SSH-терминал и файлы доступны независимо от Hub."
        default:
            return "Состояние сервера не подтверждено."
        }
    }

    @ViewBuilder private var content: some View {
        if let url = tunnel.localURL { connectedPanel(url: url) }
        else { connections }
    }

    private func connectedPanel(url: URL) -> some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(tunnel.routeRecoveryBusy || tunnel.routeRecoveryNeeded ? .orange : .green)
                    .frame(width: 8, height: 8)
                Text(tunnel.status).font(.caption).lineLimit(1)
                Spacer()
                Button("Отключить") { stopPanel() }.font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 9)
            if tunnel.routeRecoveryBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Проверяем действующий путь панели…").font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
            }
            if tunnel.routeRecoveryNeeded {
                HStack {
                    Text("Панель временно недоступна; SSH-соединение сохранено.")
                        .font(.caption)
                    Spacer()
                    Button("Повторить проверку пути") { tunnel.recoverPanelRoute() }
                        .font(.caption)
                }
                .padding(.horizontal)
            }
            HStack {
                Button("Получить пароль первого входа") { tunnel.fetchBootstrapPassword() }
                    .font(.caption)
                    .disabled(tunnel.bootstrapBusy)
                if tunnel.bootstrapBusy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            if tunnel.canUseSSHLogin {
                Button("Войти через SSH") {
                    guard let webView = panelWebView, webView.url == url else { return }
                    requestNativeLogin(webView, url: url, retry: true)
                }
                .font(.caption)
                .disabled(panelWebView == nil || tunnel.routeRecoveryBusy || tunnel.routeRecoveryNeeded)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            LocalPanelWebView(url: url, onPolicyFailure: { tunnel.webPolicyFailed(for: url) },
                              onReady: { webView in
                panelWebView = webView
                requestNativeLogin(webView, url: url, retry: false)
            }, onRouteCandidate: { candidate, stillCurrent in
                tunnel.refreshPanelRoute(navigatedTo: candidate, stillCurrent: stillCurrent)
            }, onRouteUnavailable: { tunnel.recoverPanelRoute() })
                .id("\(url.absoluteString)#\(tunnel.routeRevision)")
        }
    }

    private func requestNativeLogin(_ webView: WKWebView, url: URL, retry: Bool) {
        tunnel.fetchNativeSSHGrant(retry: retry) { [weak tunnel, weak webView] grant in
            guard let tunnel, tunnel.localURL == url,
                  !tunnel.routeRecoveryBusy, !tunnel.routeRecoveryNeeded,
                  let webView, webView.url == url, webView.window != nil,
                  let grant, let literal = SSHGrantResponse.javaScriptLiteral(grant) else { return }
            webView.evaluateJavaScript(
                "if (typeof globalThis.sovagridRedeemNativeSSHGrant === 'function') " +
                "globalThis.sovagridRedeemNativeSSHGrant(\(literal));",
                completionHandler: nil
            )
        }
    }

    private var connections: some View {
        List {
            Section {
                Text("Панель SovaGrid откроется по SSH на выбранном узле. Для профиля с промежуточным узлом можно открыть Hub на нём или на конечном сервере. Каждый вариант направляет трафик на свой 127.0.0.1:8766.")
                    .foregroundStyle(.secondary)
                Text(tunnel.status).font(.subheadline)
                if tunnel.installBusy { ProgressView().controlSize(.small) }
            }
            Section("SSH-подключение") {
                ForEach(servers.servers) { profile in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.name).font(.headline)
                        if let jump = profile.jump {
                            Button { tunnel.start(via: profile, endpoint: .entry) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Hub на промежуточном узле")
                                    Text(jump.address).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            .disabled(tunnel.installBusy || tunnel.status == "Подключение по SSH…")
                            Button { tunnel.start(via: profile, endpoint: .target) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Hub на конечном сервере")
                                    Text(profile.address).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            .disabled(tunnel.installBusy || tunnel.status == "Подключение по SSH…")
                        } else {
                            Button { tunnel.start(via: profile, endpoint: .target) } label: {
                                Text("Открыть Hub: \(profile.address)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            .disabled(tunnel.installBusy || tunnel.status == "Подключение по SSH…")
                        }
                    }
                }
                if servers.servers.isEmpty {
                    Text("Сначала добавьте SSH-сервер на вкладке SSH.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct BootstrapPasswordSheet: View {
    @ObservedObject var tunnel: PanelTunnel
    @State private var revealed = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Начальный пароль admin").font(.headline)
                if let password = tunnel.bootstrapPassword {
                    Text(revealed ? password : String(repeating: "•", count: min(password.count, 16)))
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel(revealed ? password : "Пароль скрыт")
                    HStack(spacing: 16) {
                        Button(revealed ? "Скрыть" : "Показать") { revealed.toggle() }
                        Button("Скопировать") { BootstrapPasswordClipboard.copy(password) }
                    }
                }
                Text("Это пароль только для первого входа. После смены пароля в настройках панели файл на сервере останется прежним, и этот пароль больше не подойдёт.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("Первый вход")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { tunnel.clearBootstrapPassword() }
                }
            }
        }
        .onDisappear { tunnel.clearBootstrapPassword() }
    }

}

@MainActor private enum BootstrapPasswordClipboard {
    private static var copiedChangeCount: Int?

    static func copy(_ password: String) {
#if os(iOS)
        let pasteboard = UIPasteboard.general
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: password]],
            options: [.expirationDate: Date().addingTimeInterval(60), .localOnly: true]
        )
        copiedChangeCount = pasteboard.changeCount
#elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(password, forType: .string)
        copiedChangeCount = pasteboard.changeCount
#endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            clearIfUnchanged()
        }
    }

    static func clearIfUnchanged() {
        guard let copiedChangeCount else { return }
        self.copiedChangeCount = nil
#if os(iOS)
        let pasteboard = UIPasteboard.general
        if pasteboard.changeCount == copiedChangeCount { pasteboard.items = [] }
#elseif os(macOS)
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == copiedChangeCount { pasteboard.clearContents() }
#endif
    }
}

private struct LocalPanelWebView {
    let url: URL
    let onPolicyFailure: () -> Void
    let onReady: (WKWebView) -> Void
    let onRouteCandidate: (URL, @escaping () -> Bool) -> Void
    let onRouteUnavailable: () -> Void

    func makeWebView(coordinator: LocalPanelCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(
            ProfileScriptMessageProxy(coordinator: coordinator), name: "sovagridNativeProfile"
        )
        configuration.userContentController.add(
            ProfileScriptMessageProxy(coordinator: coordinator), name: "sovagridNativeFiles"
        )
        configuration.userContentController.add(
            ProfileScriptMessageProxy(coordinator: coordinator), name: "sovagridRestoreChannel"
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: PanelFileTransferScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        coordinator.bind(webView)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Apply the network rule before the first request. The rule also covers page
        // subresources and fetch() calls, which WKNavigationDelegate does not see.
        let escapedOrigin = "^http://127[.]0[.]0[.]1:\(url.port ?? 0)/"
        let rules = """
        [{"trigger":{"url-filter":"^http://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^https://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ws://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"\(escapedOrigin)"},"action":{"type":"ignore-previous-rules"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "sovagrid-panel-\(url.port ?? 0)", encodedContentRuleList: rules
        ) { list, _ in
            DispatchQueue.main.async {
                guard coordinator.isActive(webView) else { return }
                guard let list else {
                    coordinator.onPolicyFailure()
                    return
                }
                webView.configuration.userContentController.add(list)
                webView.load(URLRequest(url: url))
            }
        }
        return webView
    }
}

/// WKUserContentController retains its handler; this proxy must not retain the coordinator.
private final class ProfileScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var coordinator: LocalPanelCoordinator?

    init(coordinator: LocalPanelCoordinator) { self.coordinator = coordinator }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "sovagridNativeFiles" { coordinator?.receiveFile(message) }
        else if message.name == "sovagridRestoreChannel" { coordinator?.receiveRestore(message) }
        else { coordinator?.receiveProfile(message) }
    }
}

#if os(iOS)
private final class RestoreDocumentPicker: UIDocumentPickerViewController {}
#endif

private final class LocalPanelCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let origin: URL
    let onPolicyFailure: () -> Void
    let onReady: (WKWebView) -> Void
    let onRouteCandidate: (URL, @escaping () -> Bool) -> Void
    let onRouteUnavailable: () -> Void
    private weak var activeWebView: WKWebView?
    private var invalidated = false
    private var nativeGrantAttempted = false
    private var acceptedMainFrameURL: URL?
    private var download: PanelDownloadSession?
    private var downloadPromptId: String?
    private var uploadCompletion: (([URL]?) -> Void)?
    private var uploadedFiles: [PanelUploadFile] = []
    private var restoreSession = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    private var restorePending: PanelRestoreMessage?
    private var restoreFiles: PanelRestoreFiles?
    private var restoreOpening: PanelRestoreFiles?
    private var restoreReadId: String?
#if os(iOS)
    private var temporaryProfileDirectory: URL?
    private weak var activityController: UIActivityViewController?
    private weak var downloadPrompt: UIAlertController?
    private weak var uploadPicker: UIDocumentPickerViewController?
    private weak var downloadPicker: UIDocumentPickerViewController?
    private weak var restorePicker: RestoreDocumentPicker?
#elseif os(macOS)
    private var savePanel: NSSavePanel?
    private var pendingProfile: ProfileExportPayload?
    private var uploadPanel: NSOpenPanel?
    private var restorePanel: NSOpenPanel?
#endif

    init(origin: URL, onPolicyFailure: @escaping () -> Void, onReady: @escaping (WKWebView) -> Void,
         onRouteCandidate: @escaping (URL, @escaping () -> Bool) -> Void,
         onRouteUnavailable: @escaping () -> Void) {
        self.origin = origin
        self.onPolicyFailure = onPolicyFailure
        self.onReady = onReady
        self.onRouteCandidate = onRouteCandidate
        self.onRouteUnavailable = onRouteUnavailable
        super.init()
#if os(iOS)
        NotificationCenter.default.addObserver(self, selector: #selector(cleanupForBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
#endif
    }

    deinit {
        restoreFiles?.close(); restoreOpening?.close()
        NotificationCenter.default.removeObserver(self)
#if os(iOS)
        removeTemporaryProfile()
#endif
    }

    func bind(_ webView: WKWebView) { activeWebView = webView }

    func isActive(_ webView: WKWebView) -> Bool {
        !invalidated && activeWebView === webView
    }

    func invalidate(_ webView: WKWebView) {
        guard isActive(webView) else { return }
        invalidated = true
        activeWebView = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sovagridNativeProfile")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sovagridNativeFiles")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sovagridRestoreChannel")
        closeRestoreAccess()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        downloadPromptId = nil
        download?.discard(); download = nil
        uploadCompletion?(nil); uploadCompletion = nil
        uploadedFiles.removeAll()
#if os(iOS)
        downloadPrompt?.dismiss(animated: false)
        uploadPicker?.dismiss(animated: false)
        downloadPicker?.dismiss(animated: false)
        activityController?.dismiss(animated: false)
        removeTemporaryProfile()
#elseif os(macOS)
        savePanel?.cancel(nil)
        savePanel = nil
        pendingProfile = nil
        uploadPanel?.cancel(nil); uploadPanel = nil
#endif
    }

    private func closeRestoreAccess() {
        restorePending = nil
        restoreReadId = nil
        restoreFiles?.close(); restoreFiles = nil
        restoreOpening?.close(); restoreOpening = nil
#if os(iOS)
        let picker = restorePicker; restorePicker = nil
        picker?.dismiss(animated: false)
#elseif os(macOS)
        let panel = restorePanel; restorePanel = nil
        panel?.cancel(nil)
#endif
    }

    private func replyRestore(_ request: PanelRestoreMessage, result: [String: Any], webView: WKWebView) {
        guard isActive(webView), request.session == restoreSession, allowed(webView.url),
              let body = PanelRestoreContract.replyJSON(result) else { return }
        webView.evaluateJavaScript("globalThis.__sovagridRestoreReply?.(\"\(request.session)\",\"\(request.id)\",\(body));",
                                  completionHandler: nil)
    }

    func receiveRestore(_ message: WKScriptMessage) {
        guard message.name == "sovagridRestoreChannel", let webView = message.webView,
              isActive(webView), webView.window != nil, message.frameInfo.isMainFrame,
              allowed(message.frameInfo.request.url), allowed(webView.url) else { return }
        let source = message.frameInfo.securityOrigin
        guard source.protocol == "http", source.host == "127.0.0.1", source.port == origin.port,
              let request = PanelRestoreMessage.parse(message.body), request.session == restoreSession else { return }
        switch request.action {
        case "release":
            closeRestoreAccess()
            replyRestore(request, result: ["ok": true], webView: webView)
        case "pick":
            guard restorePending == nil, restoreOpening == nil, uploadCompletion == nil,
                  download == nil, downloadPromptId == nil else {
                replyRestore(request, result: ["ok": false, "error": "Сначала завершите текущий выбор или передачу файла."], webView: webView)
                return
            }
            closeRestoreAccess()
            restorePending = request
#if os(iOS)
            guard let presenter = webView.window?.rootViewController,
                  presenter.presentedViewController == nil else {
                restorePending = nil
                replyRestore(request, result: ["ok": false, "error": "Закройте другое окно и повторите выбор файлов."], webView: webView)
                return
            }
            let picker = RestoreDocumentPicker(forOpeningContentTypes: [.data], asCopy: false)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            restorePicker = picker
            presenter.present(picker, animated: true)
#elseif os(macOS)
            guard let window = webView.window, savePanel == nil, uploadPanel == nil else {
                restorePending = nil
                replyRestore(request, result: ["ok": false, "error": "Закройте другое окно и повторите выбор файлов."], webView: webView)
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
            panel.message = "Выберите до пяти файлов копии: до 8 ГБ каждый, до 16 ГБ всего. Они читаются по частям."
            restorePanel = panel
            panel.beginSheetModal(for: window) { [weak self, weak webView] response in
                guard let self, let webView, self.restorePanel === panel,
                      self.restorePending?.id == request.id, request.session == self.restoreSession else { return }
                self.restorePanel = nil
                if response == .OK { self.finishRestoreSelection(panel.urls, request: request, webView: webView) }
                else {
                    self.restorePending = nil
                    self.replyRestore(request, result: ["ok": false, "error": "Выбор файлов отменён."], webView: webView)
                }
            }
#endif
        case "read":
            guard let files = restoreFiles, let handle = request.handle,
                  let offset = request.offset, let length = request.length, restoreReadId == nil else {
                replyRestore(request, result: ["ok": false, "error": "Выбор закрыт или предыдущее чтение ещё не завершено."], webView: webView)
                return
            }
            restoreReadId = request.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak webView] in
                let data = try? files.read(handle: handle, offset: offset, length: length)
                let encoded = data?.base64EncodedString()
                DispatchQueue.main.async {
                    guard let self, let webView else { return }
                    if self.restoreReadId == request.id { self.restoreReadId = nil }
                    guard self.restoreFiles === files, request.session == self.restoreSession else { return }
                    if let encoded { self.replyRestore(request, result: ["ok": true, "data": encoded], webView: webView) }
                    else {
                        files.close(); self.restoreFiles = nil
                        self.replyRestore(request, result: ["ok": false, "error": "Файл изменился или недоступен. Скопируйте его на устройство и выберите снова."], webView: webView)
                    }
                }
            }
        default: break
        }
    }

    private func finishRestoreSelection(_ urls: [URL], request: PanelRestoreMessage, webView: WKWebView) {
        guard restorePending?.id == request.id, request.session == restoreSession, isActive(webView) else { return }
        restorePending = nil
        guard (1...5).contains(urls.count) else {
            replyRestore(request, result: ["ok": false, "error": PanelRestoreContract.copyMessage], webView: webView)
            return
        }
        let files = PanelRestoreFiles()
        restoreOpening = files
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak webView] in
            let selected: [[String: Any]]?
            do { selected = try urls.map { try files.add($0) } }
            catch { files.close(); selected = nil }
            DispatchQueue.main.async {
                guard let self, let webView else { files.close(); return }
                guard self.restoreOpening === files, request.session == self.restoreSession,
                      self.isActive(webView), webView.window != nil else { files.close(); return }
                self.restoreOpening = nil
                if let selected {
                    self.restoreFiles?.close(); self.restoreFiles = files
                    self.replyRestore(request, result: ["ok": true, "files": selected], webView: webView)
                } else {
                    self.replyRestore(request, result: ["ok": false, "error": PanelRestoreContract.copyMessage], webView: webView)
                }
            }
        }
    }

    private func allowed(_ candidate: URL?) -> Bool {
        guard let candidate else { return false }
        return candidate.scheme?.lowercased() == "http"
            && candidate.host == "127.0.0.1"
            && candidate.port == origin.port
            && candidate.user == nil
            && candidate.password == nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isActive(webView), let current = webView.url,
              acceptedMainFrameURL == current else { return }
        if allowed(current), let port = origin.port {
            webView.evaluateJavaScript(PanelRestoreScript.source(session: restoreSession,
                origin: "http://127.0.0.1:\(port)"), completionHandler: nil)
        }
        if current == origin {
            if !nativeGrantAttempted {
                nativeGrantAttempted = true
                onReady(webView)
            }
            return
        }
        guard allowed(current) else { return }
        onRouteCandidate(current) { [weak self, weak webView] in
            guard let self, let webView else { return false }
            return self.isActive(webView) && webView.window != nil && webView.url == current
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        closeRestoreAccess()
        restoreSession = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        acceptedMainFrameURL = nil
    }

    func receiveProfile(_ message: WKScriptMessage) {
        guard message.name == "sovagridNativeProfile",
              let webView = message.webView,
              isActive(webView),
              webView.window != nil,
              message.frameInfo.isMainFrame,
              allowed(message.frameInfo.request.url),
              allowed(webView.url) else { return }
        let source = message.frameInfo.securityOrigin
        guard source.protocol == "http", source.host == "127.0.0.1",
              source.port == origin.port,
              download == nil, downloadPromptId == nil,
              let profile = ProfileExportPayload.parse(message.body) else { return }
#if os(iOS)
        shareProfile(profile, from: webView)
#elseif os(macOS)
        saveProfile(profile, from: webView)
#endif
    }

    func receiveFile(_ message: WKScriptMessage) {
        guard message.name == "sovagridNativeFiles", let webView = message.webView,
              isActive(webView), webView.window != nil, message.frameInfo.isMainFrame,
              allowed(message.frameInfo.request.url), allowed(webView.url) else { return }
        let source = message.frameInfo.securityOrigin
        guard source.protocol == "http", source.host == "127.0.0.1", source.port == origin.port,
              let request = PanelDownloadMessage.parse(message.body) else { return }
        if request.operation == "cancel", downloadPromptId == request.id {
            downloadPromptId = nil
#if os(iOS)
            downloadPrompt?.dismiss(animated: false)
#endif
            return
        }
        if request.operation == "start" {
            guard download == nil, downloadPromptId == nil, uploadCompletion == nil,
                  restorePending == nil, restoreOpening == nil else {
                replyFile(request, accepted: false, webView: webView); return
            }
#if os(iOS)
            guard activityController == nil else { replyFile(request, accepted: false, webView: webView); return }
#elseif os(macOS)
            guard savePanel == nil else { replyFile(request, accepted: false, webView: webView); return }
#endif
            confirmDownload(request, webView: webView)
            return
        }
        guard let download, download.id == request.id else {
            replyFile(request, accepted: false, webView: webView); return
        }
        if request.operation == "cancel" {
            download.discard(); self.download = nil
            showFileError(webView: webView)
            return
        }
        do {
            try download.accept(request)
            replyFile(request, accepted: true, webView: webView)
            if download.complete { exportDownload(download, webView: webView) }
        } catch {
            download.discard(); self.download = nil
            replyFile(request, accepted: false, webView: webView)
            showFileError(webView: webView)
        }
    }

    private func replyFile(_ request: PanelDownloadMessage, accepted: Bool, webView: WKWebView) {
        // Both identifiers have already passed the fixed grammar in the parser.
        guard isActive(webView) else { return }
        webView.evaluateJavaScript("globalThis.__sovagridFileReply?.('\(request.id)', '\(request.step)', \(accepted ? "true" : "false"));", completionHandler: nil)
    }

    private func confirmDownload(_ request: PanelDownloadMessage, webView: WKWebView) {
        guard let filename = request.filename else { return }
        downloadPromptId = request.id
        let decision: (Bool) -> Void = { [weak self, weak webView] accepted in
            guard let self, let webView, self.isActive(webView), self.downloadPromptId == request.id else { return }
            self.downloadPromptId = nil
            guard accepted else { self.replyFile(request, accepted: false, webView: webView); return }
            do {
                self.download = try PanelDownloadSession(id: request.id, filename: filename)
                self.replyFile(request, accepted: true, webView: webView)
            } catch {
                self.replyFile(request, accepted: false, webView: webView)
                self.showFileError(webView: webView)
            }
        }
        let explanation = "\(filename)\n\nФайл может содержать пароли и ключи сервера. Он будет загружен через текущий SSH-туннель, затем вы выберете, куда сохранить его. До 32 ГБ; на устройстве нужно свободное место для временной копии."
#if os(iOS)
        guard let presenter = webView.window?.rootViewController else { decision(false); return }
        let alert = UIAlertController(title: "Скачать файл?", message: explanation, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in decision(false) })
        alert.addAction(UIAlertAction(title: "Скачать", style: .default) { _ in decision(true) })
        downloadPrompt = alert
        presenter.present(alert, animated: true)
#elseif os(macOS)
        guard let window = webView.window else { decision(false); return }
        let alert = NSAlert(); alert.messageText = "Скачать файл?"; alert.informativeText = explanation
        alert.addButton(withTitle: "Скачать"); alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { decision($0 == .alertFirstButtonReturn) }
#endif
    }

    private func exportDownload(_ session: PanelDownloadSession, webView: WKWebView) {
#if os(iOS)
        guard let presenter = webView.window?.rootViewController else { download = nil; return }
        let picker = UIDocumentPickerViewController(forExporting: [session.file], asCopy: true)
        picker.delegate = self
        downloadPicker = picker
        presenter.present(picker, animated: true)
#elseif os(macOS)
        guard let window = webView.window else { download = nil; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.filename; panel.canCreateDirectories = true
        savePanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak session] response in
            guard let self, let session, self.download === session else { return }
            defer { self.savePanel = nil; self.download = nil }
            guard response == .OK, let destination = panel.url else { return }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".sovagrid-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try FileManager.default.copyItem(at: session.file, to: temporary)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                guard Darwin.rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            } catch { self.showFileError(webView: webView) }
        }
#endif
    }

    private func showFileError(webView: WKWebView) {
#if os(iOS)
        guard let presenter = webView.window?.rootViewController else { return }
        let alert = UIAlertController(title: "Файл не сохранён", message: "Передача прервалась, файл превышает 32 ГБ или на устройстве недостаточно места. Временная копия удалена. Повторите скачивание из панели.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ОК", style: .default)); presenter.present(alert, animated: true)
#elseif os(macOS)
        guard let window = webView.window else { return }
        let alert = NSAlert(); alert.messageText = "Файл не сохранён"
        alert.informativeText = "Проверьте свободное место и повторите скачивание из панели. Временная копия удалена."
        alert.beginSheetModal(for: window, completionHandler: nil)
#endif
    }

#if os(iOS)
    @objc private func cleanupForBackground() {
        closeRestoreAccess()
        downloadPromptId = nil
        downloadPrompt?.dismiss(animated: false)
        download?.discard(); download = nil
        uploadCompletion?(nil); uploadCompletion = nil
        uploadedFiles.removeAll()
        uploadPicker?.dismiss(animated: false)
        downloadPicker?.dismiss(animated: false)
        activityController?.dismiss(animated: false)
        removeTemporaryProfile()
    }

    private func removeTemporaryProfile() {
        if let directory = temporaryProfileDirectory {
            try? FileManager.default.removeItem(at: directory)
            temporaryProfileDirectory = nil
        }
    }

    private func shareProfile(_ profile: ProfileExportPayload, from webView: WKWebView) {
        guard temporaryProfileDirectory == nil,
              let presenter = webView.window?.rootViewController else { return }
        let manager = FileManager.default
        let directory = ProfileExportTemporaryFiles.directory(for: UUID())
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: NSNumber(value: 0o700)])
            let file = directory.appendingPathComponent(profile.filename, isDirectory: false)
            try profile.data.write(to: file, options: [.atomic, .completeFileProtection])
            try manager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: file.path)
            temporaryProfileDirectory = directory
            let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = webView
            controller.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX,
                                                                           y: webView.bounds.midY,
                                                                           width: 1, height: 1)
            controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
                self?.removeTemporaryProfile()
            }
            activityController = controller
            var top = presenter
            while let next = top.presentedViewController { top = next }
            top.present(controller, animated: true)
        } catch {
            try? manager.removeItem(at: directory)
            showSaveError(on: presenter)
        }
    }

    private func showSaveError(on presenter: UIViewController) {
        let alert = UIAlertController(title: "Не удалось подготовить профиль",
                                      message: "Попробуйте сохранить профиль ещё раз.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ОК", style: .default))
        presenter.present(alert, animated: true)
    }
#elseif os(macOS)
    private func saveProfile(_ profile: ProfileExportPayload, from webView: WKWebView) {
        guard savePanel == nil, let window = webView.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = profile.filename
        panel.canCreateDirectories = true
        savePanel = panel
        pendingProfile = profile
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, let panel, self.savePanel === panel else { return }
            defer {
                self.pendingProfile = nil
                self.savePanel = nil
            }
            guard response == .OK,
                  let destination = panel.url,
                  let data = self.pendingProfile?.data else { return }
            do {
                try self.writeProtectedProfile(data, to: destination)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Не удалось сохранить профиль"
                alert.informativeText = "Выберите другой путь и попробуйте ещё раз."
                alert.runModal()
            }
        }
    }

    private func writeProtectedProfile(_ data: Data, to destination: URL) throws {
        // Data.write(.atomic) creates a 0644 temporary file with the default
        // umask. Create it as 0600 from the outset, in the selected directory.
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".sovagrid-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path,
                                     O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
#endif

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let external = TelegramExternalLink.destination(navigationAction.request.url),
           isActive(webView), webView.window != nil,
           navigationAction.navigationType == .linkActivated,
           navigationAction.sourceFrame.isMainFrame,
           allowed(navigationAction.sourceFrame.request.url),
           allowed(webView.url) {
            let source = navigationAction.sourceFrame.securityOrigin
            if source.protocol == "http", source.host == "127.0.0.1", source.port == origin.port {
                decisionHandler(.cancel)
#if os(iOS)
                UIApplication.shared.open(external)
#elseif os(macOS)
                NSWorkspace.shared.open(external)
#endif
                return
            }
        }
        decisionHandler(allowed(navigationAction.request.url) && navigationAction.targetFrame != nil ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard allowed(navigationResponse.response.url) else {
            decisionHandler(.cancel)
            return
        }
        if navigationResponse.isForMainFrame {
            guard let response = navigationResponse.response as? HTTPURLResponse,
                  response.statusCode == 200, response.mimeType == "text/html" else {
                acceptedMainFrameURL = nil
                decisionHandler(.cancel)
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView, self.isActive(webView) else { return }
                    self.onRouteUnavailable()
                }
                return
            }
            acceptedMainFrameURL = response.url
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    @available(iOS 18.4, macOS 10.12, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard isActive(webView), webView.window != nil, frame.isMainFrame,
              allowed(frame.request.url), allowed(webView.url), uploadCompletion == nil,
              download == nil, downloadPromptId == nil, uploadedFiles.count < 16,
              restorePending == nil, restoreOpening == nil,
              frame.securityOrigin.protocol == "http", frame.securityOrigin.host == "127.0.0.1",
              frame.securityOrigin.port == origin.port else { completionHandler(nil); return }
        uploadCompletion = completionHandler
#if os(iOS)
        guard let presenter = webView.window?.rootViewController else { finishUpload(nil, webView: webView); return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        uploadPicker = picker
        presenter.present(picker, animated: true)
#elseif os(macOS)
        guard let window = webView.window else { finishUpload(nil, webView: webView); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите один файл до 4 МБ. Он будет передан только текущей панели через SSH."
        uploadPanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak webView] response in
            guard let self, let webView else { return }
            self.uploadPanel = nil
            self.finishUpload(response == .OK ? panel.url : nil, webView: webView)
        }
#endif
    }

    private func finishUpload(_ url: URL?, webView: WKWebView) {
        guard let completion = uploadCompletion else { return }
        uploadCompletion = nil
        guard let url, isActive(webView), webView.window != nil else { completion(nil); return }
        do {
            let snapshot = try PanelUploadFile(source: url)
            uploadedFiles.append(snapshot)
            completion([snapshot.file])
        } catch {
            completion(nil)
#if os(iOS)
            guard let presenter = webView.window?.rootViewController else { return }
            let alert = UIAlertController(title: "Файл не выбран", message: "Выберите один обычный файл размером до 4 МБ.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "ОК", style: .default)); presenter.present(alert, animated: true)
#elseif os(macOS)
            guard let window = webView.window else { return }
            let alert = NSAlert(); alert.messageText = "Файл не выбран"; alert.informativeText = "Выберите один обычный файл размером до 4 МБ."
            alert.beginSheetModal(for: window, completionHandler: nil)
#endif
        }
    }
}

#if os(iOS)
extension LocalPanelCoordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if controller is RestoreDocumentPicker {
            guard controller === restorePicker, let request = restorePending,
                  let webView = activeWebView else { return }
            restorePicker = nil
            finishRestoreSelection(urls, request: request, webView: webView)
            return
        }
        if controller === downloadPicker {
            downloadPicker = nil
            download = nil
            return
        }
        uploadPicker = nil
        guard let webView = activeWebView else { uploadCompletion?(nil); uploadCompletion = nil; return }
        finishUpload(urls.count == 1 ? urls.first : nil, webView: webView)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if controller is RestoreDocumentPicker {
            guard controller === restorePicker, let request = restorePending,
                  let webView = activeWebView else { return }
            restorePicker = nil; restorePending = nil
            replyRestore(request, result: ["ok": false, "error": "Выбор файлов отменён."], webView: webView)
            return
        }
        if controller === downloadPicker {
            downloadPicker = nil
            download = nil
            return
        }
        uploadPicker = nil
        uploadCompletion?(nil); uploadCompletion = nil
    }
}
#endif

#if os(iOS)
extension LocalPanelWebView: UIViewRepresentable {
    func makeCoordinator() -> LocalPanelCoordinator {
        LocalPanelCoordinator(origin: url, onPolicyFailure: onPolicyFailure, onReady: onReady,
                              onRouteCandidate: onRouteCandidate,
                              onRouteUnavailable: onRouteUnavailable)
    }

    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // PanelView gives the representable a new identity when the tunnel URL changes.
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: LocalPanelCoordinator) {
        coordinator.invalidate(webView)
    }
}
#elseif os(macOS)
extension LocalPanelWebView: NSViewRepresentable {
    func makeCoordinator() -> LocalPanelCoordinator {
        LocalPanelCoordinator(origin: url, onPolicyFailure: onPolicyFailure, onReady: onReady,
                              onRouteCandidate: onRouteCandidate,
                              onRouteUnavailable: onRouteUnavailable)
    }

    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // PanelView gives the representable a new identity when the tunnel URL changes.
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: LocalPanelCoordinator) {
        coordinator.invalidate(webView)
    }
}
#endif
