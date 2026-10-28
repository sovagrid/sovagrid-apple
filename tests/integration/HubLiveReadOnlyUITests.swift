// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation
import XCTest

final class HubLiveReadOnlyUITests: XCTestCase {
    private let address = "__HUB_ADDRESS__"
    private let username = "__HUB_USERNAME__"
    private let serverID = "__SERVER_ID__"
    private let serverName = "__SERVER_NAME__"
    private let protectedName = "__PROTECTED_NAME__"
    private let passwordURL = URL(string: "__PASSWORD_URL__")!

    override func setUp() { continueAfterFailure = false }

    func testHTTPSLoginAndReadOnlyDockerInventory() throws {
        let password = try String(contentsOf: passwordURL, encoding: .utf8)
        XCTAssertFalse(password.isEmpty)
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["Мониторинг"].tap()
        let hubAddress = app.textFields["https://hub.example.com"]
        hubAddress.tap()
        hubAddress.typeText(address)
        app.textFields["Логин"].tap()
        app.textFields["Логин"].typeText(username)
        app.secureTextFields["Пароль"].tap()
        app.secureTextFields["Пароль"].typeText(password)
        app.buttons["Войти"].tap()

        let adminRole = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Администратор")).firstMatch
        if !adminRole.waitForExistence(timeout: 25) {
            let alert = app.alerts["Ошибка Hub"]
            let detail = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
                .replacingOccurrences(of: password, with: "[redacted]")
            print("SOVAGRID_LIVE_HUB_DIAGNOSTIC alert=\(alert.exists) login=\(app.buttons["Войти"].exists) detail=\(detail)")
            XCTFail("Native HTTPS login did not show the admin role")
        }
        let entry = app.buttons["docker-containers-\(serverID)"]
        for _ in 0..<24 where !entry.exists { app.swipeUp() }
        if !entry.exists {
            for line in app.debugDescription.components(separatedBy: .newlines)
                where line.contains("Docker") || line.contains("Контейнер") ||
                      line.contains("Службы") || line.contains(serverName) {
                print("SOVAGRID_LIVE_HUB_DIAGNOSTIC " + line.replacingOccurrences(of: password, with: "[redacted]"))
            }
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "Expected server did not appear in the native server list")
        entry.tap()
        XCTAssertTrue(app.staticTexts["Docker на \(serverName)"].waitForExistence(timeout: 10))

        let protectedRow = app.staticTexts[protectedName]
        for _ in 0..<10 where !protectedRow.exists { app.swipeUp() }
        XCTAssertTrue(protectedRow.waitForExistence(timeout: 10),
                      "Protected Docker inventory item did not appear")
        XCTAssertTrue(app.staticTexts["Системный контейнер: управление скрыто."].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", protectedName)).firstMatch.exists,
                       "Protected workload must not open action controls")
        XCTAssertFalse(app.buttons["Проверить состояние"].exists,
                       "Read-only list should not display mutation controls")

        app.navigationBars["Контейнеры"].buttons.element(boundBy: 0).tap()
        let logout = app.buttons["Выйти"]
        XCTAssertTrue(logout.waitForExistence(timeout: 5))
        logout.tap()
        XCTAssertTrue(app.buttons["Войти"].waitForExistence(timeout: 10))
        print("SOVAGRID_LIVE_HUB_READ_ONLY_PASSED")
    }
}
