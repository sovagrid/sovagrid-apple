// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import XCTest

final class HubServiceUITests: XCTestCase {
    private let address = "__FIXTURE_ADDRESS__"

    override func setUp() { continueAfterFailure = false }

    func testAdminChecksAndConfirmsOneServiceRestart() {
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["Мониторинг"].tap()
        let hubAddress = app.textFields["https://hub.example.com"]
        hubAddress.tap()
        hubAddress.typeText(address)
        app.textFields["Логин"].tap()
        app.textFields["Логин"].typeText("fixture-service-admin")
        app.secureTextFields["Пароль"].tap()
        app.secureTextFields["Пароль"].typeText("fixture-password")
        app.buttons["Войти"].tap()

        if !label("Администратор", in: app).waitForExistence(timeout: 20) {
            print("SOVAGRID_HUB_SERVICE_DIAGNOSTIC_BEGIN\n\(app.debugDescription)\nSOVAGRID_HUB_SERVICE_DIAGNOSTIC_END")
            XCTFail("Admin login did not complete")
        }
        let services = app.buttons["Службы systemd"]
        for _ in 0..<7 where !services.exists { app.swipeUp() }
        XCTAssertTrue(services.waitForExistence(timeout: 10))
        services.tap()
        let unit = app.textFields["nginx.service"]
        XCTAssertTrue(unit.waitForExistence(timeout: 10))
        unit.tap()
        unit.typeText("nginx.service")
        app.buttons["Проверить состояние"].tap()
        XCTAssertTrue(label("Состояние подтверждено", in: app).waitForExistence(timeout: 20))

        let restart = app.buttons["Перезапустить"]
        XCTAssertTrue(restart.isEnabled)
        restart.tap()
        XCTAssertTrue(app.alerts["Подтвердить действие"].waitForExistence(timeout: 5))
        app.alerts.buttons["Перезапустить"].tap()
        XCTAssertTrue(label("Перезапустить: active", in: app).waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Перезапустить"].isEnabled,
                       "A second mutation must require a new status job")
        print("SOVAGRID_HUB_SERVICE_FLOW_PASSED")
    }

    private func label(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }
}
