// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

/// The panel may launch the two Telegram setup links, but must never fetch
/// external content inside its isolated WebView.
enum TelegramExternalLink {
    static func destination(_ candidate: URL?) -> URL? {
        guard let candidate,
              candidate.scheme?.lowercased() == "https",
              candidate.host?.lowercased() == "t.me",
              candidate.port == nil,
              candidate.user == nil,
              candidate.password == nil,
              candidate.query == nil,
              candidate.fragment == nil else { return nil }

        let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? ""
        guard path.first == "/", !path.dropFirst().contains("/"),
              (5...32).contains(path.count - 1) else { return nil }
        let username = String(path.dropFirst())
        guard username.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 95
        }) else { return nil }
        let lower = username.lowercased()
        guard lower == "botfather" || lower.hasSuffix("bot") else { return nil }
        return candidate
    }
}
