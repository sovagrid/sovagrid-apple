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
                        if let url = URL(string: "https://github.com/sovagrid/sovagrid-blueprint/releases/tag/server-v0.11.0") {
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
                return "Установить SovaGrid \(SovaGridFirstInstall.version) на выбранный Ubuntu-сервер? Сервер загрузит официальный пакет, сверит SHA-256 и повторно проверит, что SovaGrid ещё не установлен. Затем настроит Docker, локальные Hub и Agent. После проверки панель откроется здесь."
            }
            return "Для первой установки нужен вход root по SSH. На компьютере можно использовать SovaGrid Starter."
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
        coordinator?.receiveProfile(message)
    }
}

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
#if os(iOS)
    private var temporaryProfileDirectory: URL?
    private weak var activityController: UIActivityViewController?
#elseif os(macOS)
    private var savePanel: NSSavePanel?
    private var pendingProfile: ProfileExportPayload?
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
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
#if os(iOS)
        activityController?.dismiss(animated: false)
        removeTemporaryProfile()
#elseif os(macOS)
        savePanel?.cancel(nil)
        savePanel = nil
        pendingProfile = nil
#endif
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
              let profile = ProfileExportPayload.parse(message.body) else { return }
#if os(iOS)
        shareProfile(profile, from: webView)
#elseif os(macOS)
        saveProfile(profile, from: webView)
#endif
    }

#if os(iOS)
    @objc private func cleanupForBackground() {
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
}

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
