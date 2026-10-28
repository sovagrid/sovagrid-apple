// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import XCTest

final class HubIdentityUITests: XCTestCase {
    private let address = "__FIXTURE_ADDRESS__"

    override func setUp() { continueAfterFailure = false }

    func test01LoginShowsViewer() {
        let app = monitor()
        XCTAssertTrue(app.buttons["Войти"].waitForExistence(timeout: 10))
        enterIfNeeded(app.textFields["https://hub.example.com"], text: address)
        enterIfNeeded(app.textFields["Логин"], text: "fixture-phone")
        let password = app.secureTextFields["Пароль"]
        password.tap()
        password.typeText("local-fixture-password")
        app.buttons["Войти"].tap()
        let role = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Наблюдатель"))
            .firstMatch
        let ready = role.waitForExistence(timeout: 15)
        if !ready {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "hub-viewer-login-diagnostic"
            shot.lifetime = .keepAlways
            add(shot)
            print("SOVAGRID_HUB_LOGIN_DIAGNOSTIC_BEGIN\n\(app.debugDescription)\nSOVAGRID_HUB_LOGIN_DIAGNOSTIC_END")
        }
        XCTAssertTrue(ready, "Viewer role did not appear")
        XCTAssertTrue(app.staticTexts["Fixture Hub server"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Выйти"].exists)
        print("SOVAGRID_HUB_VIEWER_LOGIN_PASSED")
    }

    func test02InvalidIdentityRequiresLogin() {
        let app = monitor()
        let error = app.alerts["Ошибка Hub"]
        XCTAssertTrue(error.waitForExistence(timeout: 20), "Changed or invalid user metadata did not close the session")
        error.buttons["ОК"].tap()
        XCTAssertTrue(app.buttons["Войти"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Выйти"].exists)
        XCTAssertFalse(app.staticTexts["Fixture Hub server"].exists)
        print("SOVAGRID_HUB_INVALID_IDENTITY_REQUIRES_LOGIN")
    }

    func test03TokenStaysRemovedAfterRestart() {
        let app = monitor()
        XCTAssertTrue(app.buttons["Войти"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Выйти"].exists)
        XCTAssertFalse(app.alerts["Ошибка Hub"].exists)
        print("SOVAGRID_HUB_INVALID_TOKEN_REMOVAL_PERSISTED")
    }

    private func monitor() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["Мониторинг"].tap()
        return app
    }

    private func enterIfNeeded(_ input: XCUIElement, text: String) {
        if input.value as? String == text { return }
        input.tap()
        input.typeText(text)
    }
}
