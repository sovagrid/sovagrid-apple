// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation
#if os(macOS)
import AppKit

/// Presents a system destination for a completed, bounded local download.
@MainActor
final class SFTPFileSaver {
    private var completion: (() -> Void)?
    private var savePanel: NSSavePanel?

    @discardableResult
    func present(_ file: URL, completion: @escaping () -> Void) -> Bool {
        guard self.completion == nil else { return false }
        guard let window = NSApp.keyWindow else { return false }
        self.completion = completion
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.canCreateDirectories = true
        savePanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] result in
            guard let self, let panel, self.savePanel === panel else { return }
            if result == .OK, let destination = panel.url {
                do { try self.saveCopy(from: file, to: destination) }
                catch {
                    let alert = NSAlert()
                    alert.messageText = "Не удалось сохранить файл"
                    alert.informativeText = "Выберите другое место и попробуйте ещё раз."
                    alert.runModal()
                }
            }
            self.complete()
        }
        return true
    }

    func cancel() {
        savePanel?.cancel(nil)
        complete()
    }

    private func complete() {
        let callback = completion
        completion = nil
        savePanel = nil
        callback?()
    }

    private func saveCopy(from source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".sovagrid-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
#endif
