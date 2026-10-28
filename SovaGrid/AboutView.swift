// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation
import SwiftUI

private struct LegalDocument: Identifiable {
    let title: String
    let path: String
    var id: String { path }
}

private struct LegalPackage: Identifiable {
    let name: String
    let folder: String
    let license: String
    let extras: [String]
    var id: String { folder }

    var documents: [LegalDocument] {
        [LegalDocument(title: "Лицензия", path: "ThirdParty/\(folder)/\(license)")]
        + extras.map { LegalDocument(title: $0, path: "ThirdParty/\(folder)/\($0)") }
    }
}

struct AboutView: View {
    private let source = URL(string: "https://github.com/sovagrid/sovagrid-apple")!
    private let productDocuments = [
        LegalDocument(title: "GNU AGPL v3 — полный текст", path: "LICENSE"),
        LegalDocument(title: "Дополнительные условия и авторство", path: "ATTRIBUTION.md"),
        LegalDocument(title: "Уведомление об авторстве", path: "NOTICE")
    ]
    private let packages = [
        LegalPackage(name: "SwiftTerm 1.11.2", folder: "swiftterm-1.11.2", license: "LICENSE", extras: []),
        LegalPackage(name: "SwiftNIO SSH 0.13.0", folder: "swift-nio-ssh-0.13.0", license: "LICENSE.txt", extras: []),
        LegalPackage(name: "SwiftNIO 2.104.0", folder: "swift-nio-2.104.0", license: "LICENSE.txt",
                     extras: ["NOTICE.txt", "CNIOLLHTTP-LICENSE"]),
        LegalPackage(name: "Swift Crypto 3.15.1", folder: "swift-crypto-3.15.1", license: "LICENSE.txt",
                     extras: ["NOTICE.txt"]),
        LegalPackage(name: "Swift ASN.1 1.7.3", folder: "swift-asn1-1.7.3", license: "LICENSE.txt",
                     extras: ["NOTICE.txt"]),
        LegalPackage(name: "Swift Atomics 1.3.1", folder: "swift-atomics-1.3.1", license: "LICENSE.txt", extras: []),
        LegalPackage(name: "Swift Collections 1.7.4", folder: "swift-collections-1.7.4", license: "LICENSE.txt", extras: []),
        LegalPackage(name: "Swift System 1.8.1", folder: "swift-system-1.8.1", license: "LICENSE.txt", extras: []),
        LegalPackage(name: "Swift Argument Parser 1.8.2", folder: "swift-argument-parser-1.8.2",
                     license: "LICENSE.txt", extras: [])
    ]

    var body: some View {
        List {
            Section("Продукт") {
                Text("SovaGrid — Copyright (C) 2026 Jigokuraku01")
                Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                Text("GNU AGPL v3 (AGPL-3.0-only)")
                Link("Исходный код на GitHub", destination: source)
            }
            Section("Лицензия и авторство") {
                ForEach(productDocuments) { document in
                    NavigationLink(document.title) { LegalTextView(document: document) }
                }
            }
            Section("Сторонние компоненты") {
                ForEach(packages) { package in
                    NavigationLink(package.name) {
                        List(package.documents) { document in
                            NavigationLink(document.title) { LegalTextView(document: document) }
                        }
                        .navigationTitle(package.name)
                    }
                }
            }
        }
        .navigationTitle("О программе")
    }
}

private struct LegalTextView: View {
    let document: LegalDocument

    private var content: String {
        let url = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("LegalResources", isDirectory: true)
            .appendingPathComponent(document.path, isDirectory: false)
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? "Текст не найден в сборке приложения. Откройте LICENSE и ATTRIBUTION.md в исходном репозитории."
    }

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(document.title)
    }
}
