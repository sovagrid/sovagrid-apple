// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import XCTest

final class HubMonitoringUITests: XCTestCase {
    private let address = "__FIXTURE_ADDRESS__"

    override func setUp() { continueAfterFailure = false }

    func testViewerSeesSanitizedChecksIncidentsAndClock() {
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["Мониторинг"].tap()
        let hubAddress = app.textFields["https://hub.example.com"]
        hubAddress.tap()
        hubAddress.typeText(address)
        let username = app.textFields["Логин"]
        username.tap()
        username.typeText("fixture-viewer")
        let password = app.secureTextFields["Пароль"]
        password.tap()
        password.typeText("fixture-password")
        app.buttons["Войти"].tap()

        XCTAssertTrue(label("Наблюдатель", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(label("Активные инциденты", in: app).exists)
        XCTAssertTrue(label("Высокая загрузка CPU", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(label("Завершён", in: app).exists)
        XCTAssertTrue(label("Активен", in: app).exists)

        XCTAssertTrue(scrollTo("Диагностика времени сервера", in: app))
        label("Диагностика времени сервера", in: app).tap()
        XCTAssertTrue(scrollTo("RTC относительно системных часов", in: app))
        XCTAssertTrue(label("не измеряет точность NTP", in: app).exists)
        XCTAssertTrue(scrollTo("Проверки доступности", in: app))
        XCTAssertTrue(scrollTo("Панель HTTPS", in: app))
        XCTAssertTrue(scrollTo("SSH TCP", in: app))
        XCTAssertTrue(label("HTTP 200", in: app).exists)
        XCTAssertTrue(label("Таймаут", in: app).exists)
        XCTAssertFalse(app.debugDescription.contains("secret.example"),
                       "Viewer UI exposed a check target from an unexpected response field")
        print("SOVAGRID_HUB_MONITORING_VIEWER_PASSED")
    }

    private func label(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func scrollTo(_ text: String, in app: XCUIApplication) -> Bool {
        for _ in 0..<7 {
            if label(text, in: app).exists { return true }
            app.swipeUp()
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "hub-monitoring-missing-\(text)"
        shot.lifetime = .keepAlways
        add(shot)
        print("SOVAGRID_HUB_MONITORING_DIAGNOSTIC_BEGIN\n\(app.debugDescription)\nSOVAGRID_HUB_MONITORING_DIAGNOSTIC_END")
        return false
    }
}
