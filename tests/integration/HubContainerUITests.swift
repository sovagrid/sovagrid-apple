// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import XCTest

final class HubContainerUITests: XCTestCase {
    private let address = "__FIXTURE_ADDRESS__"

    override func setUp() { continueAfterFailure = false }

    func testDockerStatusBeforeOneConfirmedRestart() {
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["Мониторинг"].tap()
        let hubAddress = app.textFields["https://hub.example.com"]
        hubAddress.tap()
        hubAddress.typeText(address)
        app.textFields["Логин"].tap()
        app.textFields["Логин"].typeText("fixture-container-admin")
        app.secureTextFields["Пароль"].tap()
        app.secureTextFields["Пароль"].typeText("fixture-password")
        app.buttons["Войти"].tap()

        if !label("Администратор", in: app).waitForExistence(timeout: 20) {
            print("SOVAGRID_HUB_CONTAINER_DIAGNOSTIC_BEGIN\n\(app.debugDescription)\nSOVAGRID_HUB_CONTAINER_DIAGNOSTIC_END")
            XCTFail("Admin login did not complete")
        }
        let entry = app.buttons["docker-containers-11111111-1111-4111-8111-111111111111"]
        for _ in 0..<7 where !entry.exists { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(label("Системный контейнер", in: app).waitForExistence(timeout: 10))
        let site = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "site")).firstMatch
        XCTAssertTrue(site.waitForExistence(timeout: 10))
        site.tap()
        let restart = app.buttons["Перезапустить"]
        XCTAssertFalse(restart.isEnabled)
        app.buttons["Проверить состояние"].tap()
        XCTAssertTrue(label("Состояние подтверждено", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(restart.isEnabled)
        restart.tap()
        XCTAssertTrue(app.alerts["Подтвердить действие"].waitForExistence(timeout: 5))
        app.alerts.buttons["Перезапустить"].tap()
        XCTAssertTrue(label("Перезапустить: Запущен", in: app).waitForExistence(timeout: 20))
        XCTAssertFalse(restart.isEnabled, "Another mutation must require a new status job")
        print("SOVAGRID_HUB_CONTAINER_FLOW_PASSED")
    }

    private func label(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }
}
