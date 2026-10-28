// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import SwiftUI

@main
struct SovaGridApp: App {
    @StateObject private var servers = ServerStore()
    @StateObject private var hub = HubStore()
    @StateObject private var keys = SSHKeyStore()
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    init() {
        SFTPTemporaryFiles.removeStaleAtLaunch()
#if os(iOS)
        ProfileExportTemporaryFiles.removeStaleAtLaunch()
#endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ServersView()
                    .tabItem { Label("SSH", systemImage: "terminal") }
                FilesView()
                    .tabItem { Label("Файлы", systemImage: "folder") }
                HubView()
                    .tabItem { Label("Мониторинг", systemImage: "chart.xyaxis.line") }
                PanelView()
                    .tabItem { Label("Панель", systemImage: "globe") }
                AppearanceSettingsView()
                    .tabItem { Label("Настройки", systemImage: "gearshape") }
            }
            .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
            .environmentObject(servers)
            .environmentObject(hub)
            .environmentObject(keys)
        }
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section("Оформление") {
                    Picker("Тема", selection: $appearanceMode) {
                        Text("Как на устройстве").tag("system")
                        Text("Светлая").tag("light")
                        Text("Тёмная").tag("dark")
                    }
                    Text("Терминал и экраны приложения меняют тему сразу. Веб-панель также имеет собственный выбор темы.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Приложение") {
                    NavigationLink("О программе и лицензии") { AboutView() }
                }
            }
            .navigationTitle("Настройки")
        }
    }
}
