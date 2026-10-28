// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import XCTest

// run_key_import.py supplies only public test metadata in a temporary copy.
// Private keys enter the app exclusively through the system document picker.
final class KeyImportTests: XCTestCase {
    private let host = "__FIXTURE_HOST__"
    private let username = "__FIXTURE_USERNAME__"
    private let folder = "__FIXTURE_FOLDER__"
    private let fingerprint = "__FIXTURE_FINGERPRINT__"
    private let profile = "SovaGrid imported key fixture"

    override func setUp() { continueAfterFailure = false }

    func testImportKeyAndConnect() {
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["SSH"].tap()
        app.buttons["Добавить сервер"].tap()
        app.textFields["Название"].tap()
        app.textFields["Название"].typeText(profile)
        app.textFields["Адрес или IP"].tap()
        app.textFields["Адрес или IP"].typeText(host)
        app.textFields["Пользователь"].tap()
        app.textFields["Пользователь"].typeText(username + "\n")
        app.buttons["Способ, Пароль"].tap()
        app.buttons["Ключ Ed25519"].tap()
        app.buttons["Ключ сервера, Создать новый"].tap()
        app.buttons["Импортировать"].tap()
        app.buttons["Выбрать приватный ключ OpenSSH"].tap()
        selectKey(app)
        XCTAssertTrue(app.staticTexts["Выбран ключ: server_ed25519"].waitForExistence(timeout: 10))
        app.buttons["Сохранить"].tap()
        XCTAssertTrue(app.staticTexts[profile].waitForExistence(timeout: 10))
        app.staticTexts[profile].tap()

        let challenge = app.alerts["Новый ключ сервера"]
        XCTAssertTrue(challenge.waitForExistence(timeout: 15), "Fresh profile must check its host key")
        let expected = challenge.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", fingerprint)).firstMatch
        XCTAssertTrue(expected.exists, "Host fingerprint differs from authenticated fixture metadata")
        guard expected.exists else { challenge.buttons["Отмена"].tap(); return }
        challenge.buttons["Доверять"].tap()
        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Подключено:"))
            .firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 20), "Imported key did not authenticate")
        guard connected.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.typeText("printf 'SOVAGRID_IMPORT_OK\\n'; uname -s; id -un; { uname -s; id -un; } > .sovagrid-ui-result\n")
        Thread.sleep(forTimeInterval: 2)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "imported-key-ssh-terminal"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeText("exit\n")
        print("SOVAGRID_SYSTEM_PICKER_IMPORTED_KEY_AND_SSH_COMMAND_SENT")
    }

    private func selectKey(_ app: XCUIApplication) {
        let browse = app.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 30), "System document picker did not open")
        browse.tap()
        let directory = app.staticTexts[folder]
        if !directory.waitForExistence(timeout: 5) {
            let location = app.staticTexts["On My iPhone"]
            XCTAssertTrue(location.waitForExistence(timeout: 10), "Local Files provider unavailable")
            location.tap()
        }
        XCTAssertTrue(directory.waitForExistence(timeout: 10), "Disposable key folder not enumerated")
        let directoryCell = app.cells.matching(NSPredicate(format: "identifier == %@", folder + ", Folder"))
            .firstMatch
        XCTAssertTrue(directoryCell.exists, "Files folder cell unavailable")
        directoryCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let key = app.staticTexts["server_ed25519"]
        XCTAssertTrue(key.waitForExistence(timeout: 10), "Disposable key not enumerated")
        let keyCell = app.cells.containing(.staticText, identifier: "server_ed25519").firstMatch
        XCTAssertTrue(keyCell.exists, "Files key cell unavailable")
        keyCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
    }
}
