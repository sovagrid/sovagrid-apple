// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import SwiftTerm
import SwiftUI

#if os(iOS)
import UIKit

struct TerminalBridge: UIViewRepresentable {
    @ObservedObject var session: SSHSession
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(session: session) }
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        applyColors(to: view, coordinator: context.coordinator)
        session.onOutput = { [weak view] bytes in view?.feed(byteArray: bytes[...]) }
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.session = session
        applyColors(to: view, coordinator: context.coordinator)
    }
    private func applyColors(to view: TerminalView, coordinator: TerminalCoordinator) {
        guard coordinator.lastColorScheme != colorScheme else { return }
        coordinator.lastColorScheme = colorScheme
        let dark = colorScheme == .dark
        view.nativeForegroundColor = dark
            ? UIColor(red: 0.90, green: 0.93, blue: 0.97, alpha: 1)
            : UIColor(red: 0.11, green: 0.16, blue: 0.22, alpha: 1)
        view.nativeBackgroundColor = dark
            ? UIColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1)
            : UIColor(red: 0.98, green: 0.985, blue: 1, alpha: 1)
        view.installColors(TerminalTheme.palette(dark: dark))
        view.caretColor = view.nativeForegroundColor
        view.setNeedsDisplay()
    }
    static func dismantleUIView(_ view: TerminalView, coordinator: TerminalCoordinator) {
        view.terminalDelegate = nil
        coordinator.session.onOutput = nil
    }
}
#elseif os(macOS)
import AppKit

struct TerminalBridge: NSViewRepresentable {
    @ObservedObject var session: SSHSession
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> TerminalCoordinator { TerminalCoordinator(session: session) }
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        applyColors(to: view, coordinator: context.coordinator)
        session.onOutput = { [weak view] bytes in view?.feed(byteArray: bytes[...]) }
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.session = session
        applyColors(to: view, coordinator: context.coordinator)
    }
    private func applyColors(to view: TerminalView, coordinator: TerminalCoordinator) {
        guard coordinator.lastColorScheme != colorScheme else { return }
        coordinator.lastColorScheme = colorScheme
        let dark = colorScheme == .dark
        view.nativeForegroundColor = dark
            ? NSColor(red: 0.90, green: 0.93, blue: 0.97, alpha: 1)
            : NSColor(red: 0.11, green: 0.16, blue: 0.22, alpha: 1)
        view.nativeBackgroundColor = dark
            ? NSColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 1)
            : NSColor(red: 0.98, green: 0.985, blue: 1, alpha: 1)
        view.installColors(TerminalTheme.palette(dark: dark))
        view.caretColor = view.nativeForegroundColor
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalCoordinator) {
        view.terminalDelegate = nil
        coordinator.session.onOutput = nil
    }
}
#endif

#if os(iOS) || os(macOS)
final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    var session: SSHSession
    var lastColorScheme: ColorScheme?
    init(session: SSHSession) { self.session = session }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        DispatchQueue.main.async { self.session.send(bytes) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        DispatchQueue.main.async { self.session.resize(columns: newCols, rows: newRows) }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private enum TerminalTheme {
    static func palette(dark: Bool) -> [SwiftTerm.Color] {
        let colors: [UInt32] = dark ? [
            0x1B2230, 0xEC6A68, 0x56C98B, 0xE1BE63,
            0x78A8F8, 0xC995E8, 0x66CFDF, 0xDCE5EF,
            0x738197, 0xFF8B84, 0x78E3A4, 0xF3D780,
            0x99BFFF, 0xE0AEFA, 0x86E4EF, 0xFFFFFF
        ] : [
            0x243042, 0xB6323A, 0x207848, 0x8B6200,
            0x2F5FAA, 0x8743A0, 0x087A91, 0x637187,
            0x58677A, 0xC9474B, 0x248856, 0x98700D,
            0x3D70BF, 0x9953B1, 0x218AA0, 0x182433
        ]
        return colors.map { value in
            SwiftTerm.Color(red: UInt16((value >> 16) & 0xff) * 257,
                            green: UInt16((value >> 8) & 0xff) * 257,
                            blue: UInt16(value & 0xff) * 257)
        }
    }
}
#endif
