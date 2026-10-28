// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import XCTest

final class SmokeTests: XCTestCase {
    private let bundle = "com.sovagrid.app"
    private let profileName = "SovaGrid route fixture"
    // Replaced with the local macOS account by run_panel_routes.py in a temporary copy.
    private let fixtureUser = "__FIXTURE_USER__"
    private let fixturePath = "__FIXTURE_PATH__"

    func test01CreateRouteProfileAndCaptureKeys() {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launch()
        app.buttons["SSH"].tap()
        if !app.staticTexts[profileName].exists {
            let add = app.buttons["Добавить сервер"]
            XCTAssertTrue(add.waitForExistence(timeout: 15), app.debugDescription)
            add.tap()
            let name = app.textFields["Название"]
            name.tap()
            name.typeText(profileName)
            let targetAddress = app.textFields["Адрес или IP"]
            targetAddress.tap()
            targetAddress.typeText("127.0.0.1")
            let targetPort = app.textFields["Порт"]
            targetPort.tap()
            targetPort.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "22222")
            let targetUser = app.textFields["Пользователь"]
            targetUser.tap()
            targetUser.typeText(fixtureUser + "\n")
            app.buttons["Способ, Пароль"].tap()
            app.buttons["Ключ Ed25519"].tap()
            let jumpSwitch = app.switches["Подключаться через SSH"]
            jumpSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(jumpSwitch.value as? String, "1", app.debugDescription)
            let jumpAddress = app.textFields["Адрес перехода"]
            reveal(jumpAddress, in: app)
            jumpAddress.tap()
            jumpAddress.typeText("127.0.0.1")
            let jumpPort = app.textFields["Порт перехода"]
            reveal(jumpPort, in: app)
            jumpPort.tap()
            jumpPort.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "22221")
            let jumpUser = app.textFields["Пользователь перехода"]
            reveal(jumpUser, in: app)
            jumpUser.tap()
            jumpUser.typeText(fixtureUser + "\n")
            app.buttons["Вход на переходе, Пароль"].tap()
            app.buttons["Ключ Ed25519"].tap()
            app.buttons["Сохранить"].tap()
        }
        let server = app.staticTexts[profileName]
        XCTAssertTrue(server.waitForExistence(timeout: 10), app.debugDescription)
        server.tap()
        let challenge = app.alerts["Новый ключ сервера"]
        if challenge.waitForExistence(timeout: 7) { challenge.buttons["Отмена"].tap() }
        let error = app.alerts["SSH-ошибка"]
        if error.waitForExistence(timeout: 3) { error.buttons["ОК"].tap() }
        let keys = app.buttons["SSH-ключи"]
        XCTAssertTrue(keys.waitForExistence(timeout: 10), app.debugDescription)
        keys.tap()
        let publicKeys = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 ")).allElementsBoundByIndex
        XCTAssertEqual(publicKeys.count, 2, app.debugDescription)
        print("SOVAGRID_ROUTE_TARGET_PUBLIC_KEY=\(publicKeys[0].label)")
        print("SOVAGRID_ROUTE_ENTRY_PUBLIC_KEY=\(publicKeys[1].label)")
    }

    func test02OpenEntryPanelAndReadPassword() {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launch()
        let panelTab = app.buttons["Панель"]
        XCTAssertTrue(panelTab.waitForExistence(timeout: 15), app.debugDescription)
        panelTab.tap()
        XCTAssertTrue(app.staticTexts[profileName].waitForExistence(timeout: 10), app.debugDescription)
        let entryButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixtureUser + "@127.0.0.1:22221")).firstMatch
        let targetButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixtureUser + "@127.0.0.1:22222")).firstMatch
        XCTAssertTrue(entryButton.exists, app.debugDescription)
        XCTAssertTrue(targetButton.exists, app.debugDescription)
        let optionsShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        optionsShot.name = "panel-route-options"
        optionsShot.lifetime = .keepAlways
        add(optionsShot)

        entryButton.tap()
        let challenge = app.alerts["Новый ключ сервера"]
        if challenge.waitForExistence(timeout: 3) {
            let entryDetails = challenge.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "127.0.0.1:22221")).firstMatch
            XCTAssertTrue(entryDetails.exists, challenge.debugDescription)
            XCTAssertTrue(entryDetails.label.contains("SHA256:"), challenge.debugDescription)
            challenge.buttons["Доверять"].tap()
        }
        verifyPanel(app, expectedAddress: fixtureUser + "@127.0.0.1:22221", expectedPassword: "ENTRY_FIXTURE_PASSWORD_123456789")
        let switchRoute = app.webViews.firstMatch.buttons["Change panel route"]
        XCTAssertTrue(switchRoute.waitForExistence(timeout: 10), app.debugDescription)
        switchRoute.tap()
        let customPage = app.webViews.firstMatch.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "CUSTOM PANEL FIXTURE")).firstMatch
        XCTAssertTrue(customPage.waitForExistence(timeout: 35), app.debugDescription)
        app.buttons["Отключить"].tap()
        print("SOVAGRID_PANEL_ENTRY_ROUTE_PASSED")
    }

    func test03OpenTargetPanelAndReadPassword() {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launch()
        let panelTab = app.buttons["Панель"]
        XCTAssertTrue(panelTab.waitForExistence(timeout: 15), app.debugDescription)
        panelTab.tap()
        XCTAssertTrue(app.staticTexts[profileName].waitForExistence(timeout: 10), app.debugDescription)
        let targetChoice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixtureUser + "@127.0.0.1:22222")).firstMatch
        XCTAssertTrue(targetChoice.waitForExistence(timeout: 10), app.debugDescription)
        targetChoice.tap()
        let challenge = app.alerts["Новый ключ сервера"]
        if challenge.waitForExistence(timeout: 10) {
            let targetDetails = challenge.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "127.0.0.1:22222")).firstMatch
            XCTAssertTrue(targetDetails.exists, challenge.debugDescription)
            XCTAssertTrue(targetDetails.label.contains("SHA256:"), challenge.debugDescription)
            challenge.buttons["Доверять"].tap()
        }
        verifyPanel(app, expectedAddress: fixtureUser + "@127.0.0.1:22222", expectedPassword: "TARGET_FIXTURE_PASSWORD_123456789")
        app.buttons["Отключить"].tap()
        print("SOVAGRID_PANEL_TARGET_ROUTE_PASSED")
    }

    func test04StalledSSHConnectionTimesOut() {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launch()
        app.buttons["SSH"].tap()
        app.buttons["Добавить сервер"].tap()
        let name = app.textFields["Название"]
        name.tap()
        name.typeText("SovaGrid timeout fixture")
        let address = app.textFields["Адрес или IP"]
        address.tap()
        address.typeText("127.0.0.1")
        let port = app.textFields["Порт"]
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "22223")
        let user = app.textFields["Пользователь"]
        user.tap()
        user.typeText(fixtureUser + "\n")
        app.buttons["Способ, Пароль"].tap()
        app.buttons["Ключ Ed25519"].tap()
        app.buttons["Сохранить"].tap()

        let panel = app.buttons["Панель"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        panel.tap()
        let choice = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", fixtureUser + "@127.0.0.1:22223"
        )).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        choice.tap()
        let error = app.alerts["Ошибка SSH-панели"]
        XCTAssertTrue(error.waitForExistence(timeout: 40))
        XCTAssertTrue(error.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Время SSH-подключения к панели истекло"
        )).firstMatch.exists)
        error.buttons["ОК"].tap()
        XCTAssertTrue(app.staticTexts["Ошибка подключения"].waitForExistence(timeout: 5))
        XCTAssertTrue(choice.isEnabled)
        print("SOVAGRID_PANEL_STALLED_SSH_TIMEOUT_PASSED")
    }

    func test05BrowseAndDownloadSFTPOverJump() {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launch()
        let files = app.buttons["Файлы"]
        XCTAssertTrue(files.waitForExistence(timeout: 15), app.debugDescription)
        files.tap()
        let selector = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Выберите сервер")).firstMatch
        XCTAssertTrue(selector.waitForExistence(timeout: 10), app.debugDescription)
        selector.tap()
        app.buttons[profileName].tap()
        // The panel tests may already have trusted these same host keys.
        // A fresh SFTP-only run instead presents one challenge per hop.
        for _ in 0..<2 {
            let challenge = app.alerts["Новый ключ сервера"]
            guard challenge.waitForExistence(timeout: 8) else { break }
            let address = challenge.staticTexts.matching(NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "127.0.0.1:22221", "127.0.0.1:22222"
            )).firstMatch
            XCTAssertTrue(address.exists, challenge.debugDescription)
            challenge.buttons["Доверять"].tap()
        }
        let initialError = app.alerts["Ошибка SFTP"]
        if initialError.waitForExistence(timeout: 2) { initialError.buttons["ОК"].tap() }
        let path = app.textFields["Папка на сервере"]
        XCTAssertTrue(path.waitForExistence(timeout: 10), app.debugDescription)
        path.tap()
        path.typeText(XCUIKeyboardKey.delete.rawValue + fixturePath + "\n")
        let open = app.buttons["Открыть"]
        if open.isEnabled { open.tap() }
        let binary = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "files-fixture.bin")).firstMatch
        XCTAssertTrue(binary.waitForExistence(timeout: 30), app.debugDescription)
        binary.tap()
        let saveToFiles = app.cells["Save to Files"]
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.exists, "Приложение должно остаться запущенным при открытии системного сохранения.")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "sftp-download-system-save"
        shot.lifetime = .keepAlways
        add(shot)
        print("SOVAGRID_SFTP_PROXYJUMP_DOWNLOAD_REQUESTED")
    }

    func test06AboutAndKeyImportControls() {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launch()
        app.buttons["Настройки"].tap()
        let about = app.buttons["О программе и лицензии"]
        XCTAssertTrue(about.waitForExistence(timeout: 10), app.debugDescription)
        about.tap()
        XCTAssertTrue(app.staticTexts["SovaGrid — Copyright (C) 2026 Jigokuraku01"]
            .waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["GNU AGPL v3 — полный текст"].tap()
        XCTAssertTrue(app.navigationBars["GNU AGPL v3 — полный текст"]
            .waitForExistence(timeout: 10), app.debugDescription)

        app.buttons["SSH"].tap()
        app.buttons["Добавить сервер"].tap()
        app.buttons["Способ, Пароль"].tap()
        app.buttons["Ключ Ed25519"].tap()
        app.buttons["Ключ сервера, Создать новый"].tap()
        app.buttons["Импортировать"].tap()
        XCTAssertTrue(app.buttons["Выбрать приватный ключ OpenSSH"].exists, app.debugDescription)
        let jumpSwitch = app.switches["Подключаться через SSH"]
        jumpSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.swipeUp()
        app.buttons["Вход на переходе, Пароль"].tap()
        app.buttons["Ключ Ed25519"].tap()
        app.buttons["Ключ перехода, Создать новый"].tap()
        app.buttons["Импортировать"].tap()
        XCTAssertTrue(app.buttons["Выбрать ключ промежуточного сервера"].exists,
                      app.debugDescription)
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.alerts["Ошибка ключа или профиля"].waitForExistence(timeout: 5))
        app.alerts.buttons["ОК"].tap()
        app.buttons["Отмена"].tap()
        print("SOVAGRID_ABOUT_AND_KEY_IMPORT_CONTROLS_PASSED")
    }

    func test07MissingImportedKeyDoesNotGenerateProfile() {
        let app = XCUIApplication(bundleIdentifier: bundle)
        app.launch()
        app.buttons["SSH"].tap()
        app.buttons["Добавить сервер"].tap()
        app.textFields["Название"].tap()
        app.textFields["Название"].typeText("Missing import fixture")
        app.textFields["Адрес или IP"].tap()
        app.textFields["Адрес или IP"].typeText("127.0.0.1")
        app.textFields["Пользователь"].tap()
        app.textFields["Пользователь"].typeText("fixture\n")
        app.buttons["Способ, Пароль"].tap()
        app.buttons["Ключ Ed25519"].tap()
        app.buttons["Ключ сервера, Создать новый"].tap()
        app.buttons["Импортировать"].tap()
        app.buttons["Сохранить"].tap()
        let alert = app.alerts["Ошибка ключа или профиля"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Выберите приватный ключ сервера.")).firstMatch.exists)
        alert.buttons["ОК"].tap()
        app.buttons["Отмена"].tap()
        XCTAssertFalse(app.staticTexts["Missing import fixture"].exists)
        print("SOVAGRID_MISSING_KEY_IMPORT_FAILS_CLOSED")
    }

    private func verifyPanel(_ app: XCUIApplication, expectedAddress: String, expectedPassword: String) {
        let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Панель через SSH:")).firstMatch
        let error = app.alerts["Ошибка SSH-панели"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !ready.exists && !error.exists {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(error.exists, error.debugDescription)
        XCTAssertTrue(ready.exists, app.debugDescription)
        XCTAssertTrue(ready.label.contains(expectedAddress), app.debugDescription)
        let page = app.webViews.firstMatch.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "LOCAL PANEL FIXTURE")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Получить пароль первого входа"].tap()
        let passwordSheet = app.navigationBars["Первый вход"]
        XCTAssertTrue(passwordSheet.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["Показать"].tap()
        XCTAssertTrue(app.staticTexts[expectedPassword].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Готово"].tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
}
