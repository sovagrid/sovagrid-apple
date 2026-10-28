// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum TelegramExternalLinkTests {
    static func main() {
        for address in [
            "https://t.me/BotFather",
            "https://t.me/MySovaGridBot",
            "https://T.ME/another_bot"
        ] {
            let url = URL(string: address)!
            precondition(TelegramExternalLink.destination(url) == url, address)
        }

        for address in [
            "http://t.me/BotFather",
            "https://evil.example/BotFather",
            "https://t.me.evil.example/BotFather",
            "https://t.me@evil.example/BotFather",
            "https://user@t.me/BotFather",
            "https://t.me:443/BotFather",
            "https://t.me/BotFather?start=payload",
            "https://t.me/BotFather#fragment",
            "https://t.me/BotFather/other",
            "https://t.me/BotFather%2Fother",
            "https://t.me/some_channel",
            "https://t.me/bot",
            "https://t.me/"
        ] {
            precondition(TelegramExternalLink.destination(URL(string: address)) == nil, address)
        }
        precondition(TelegramExternalLink.destination(nil) == nil)
        print("TelegramExternalLink: Telegram setup links allowed; external and malformed links rejected")
    }
}
