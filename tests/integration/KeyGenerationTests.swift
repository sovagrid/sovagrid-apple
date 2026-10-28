// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import XCTest

final class KeyGenerationTests: XCTestCase {
    private let targetName = "Fixture target key"
    private let jumpName = "Fixture jump key"
    private let profile = "Generated key roles fixture"

    override func setUp() { continueAfterFailure = false }

    func test01GenerateCopyAndReopenKeys() {
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["SSH"].tap()
        app.buttons["SSH-ключи"].tap()
        let target = create(app, name: targetName)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let jump = create(app, name: jumpName)
        XCTAssertNotEqual(target, jump, "Distinct key pairs must have distinct public parts")
        print("SOVAGRID_GENERATED_TARGET_PUBLIC_KEY=\(target)")
        print("SOVAGRID_GENERATED_JUMP_PUBLIC_KEY=\(jump)")
        app.terminate()
        app.launch()
        app.buttons["SSH"].tap()
        app.buttons["SSH-ключи"].tap()
        app.staticTexts[jumpName].tap()
        let publicKey = app.staticTexts["SSH public key"]
        XCTAssertTrue(publicKey.waitForExistence(timeout: 10))
        XCTAssertEqual(publicKey.label, jump, "Keychain key must survive app relaunch")
        app.buttons["Скопировать открытый ключ"].tap()
        XCTAssertTrue(app.buttons["Открытый ключ скопирован"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "generated-public-key-copy"
        shot.lifetime = .keepAlways
        add(shot)
        print("SOVAGRID_GENERATED_KEY_REOPEN_AND_COPY_PASSED")
    }

    func test02UseDistinctSavedKeysForTargetAndJump() {
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["SSH"].tap()
        app.buttons["Добавить сервер"].tap()
        type(app, field: "Название", text: profile)
        type(app, field: "Адрес или IP", text: "127.0.0.1")
        type(app, field: "Порт", text: String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "9")
        type(app, field: "Пользователь", text: "fixture\n")
        app.buttons["Способ, Пароль"].tap()
        app.buttons["Ключ Ed25519"].tap()
        app.buttons["Ключ сервера, Создать новый"].tap()
        app.buttons["Мои ключи"].tap()
        app.buttons["Мой ключ сервера, Выберите ключ"].tap()
        app.buttons[targetName].tap()
        let targetKey = app.staticTexts["SSH public key"].label
        app.swipeUp()
        let jumpSwitch = app.switches["Подключаться через SSH"]
        XCTAssertTrue(jumpSwitch.exists)
        jumpSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.swipeUp()
        type(app, field: "Адрес перехода", text: "127.0.0.1")
        type(app, field: "Порт перехода", text: String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "9")
        type(app, field: "Пользователь перехода", text: "fixture\n")
        app.buttons["Вход на переходе, Пароль"].tap()
        app.buttons["Ключ Ed25519"].tap()
        app.buttons["Ключ перехода, Создать новый"].tap()
        app.buttons["Мои ключи"].tap()
        app.buttons["Мой ключ перехода, Выберите ключ"].tap()
        app.buttons[jumpName].tap()
        let selected = app.staticTexts.matching(identifier: "SSH public key").allElementsBoundByIndex
        let jumpKey = selected.last!.label
        XCTAssertNotEqual(jumpKey, targetKey)
        app.buttons["Сохранить"].tap()
        app.staticTexts[profile].tap()
        let challenge = app.alerts["Новый ключ сервера"]
        if challenge.waitForExistence(timeout: 3) { challenge.buttons["Отмена"].tap() }
        let error = app.alerts["SSH-ошибка"]
        if error.waitForExistence(timeout: 3) { error.buttons["ОК"].tap() }
        app.buttons["SSH-ключи"].tap()
        let publicKeys = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 "))
            .allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(publicKeys, [targetKey, jumpKey], "Saved target and jump keys must preserve independent choices")
        app.buttons["Скопировать ключ перехода"].tap()
        print("SOVAGRID_GENERATED_PROFILE_TARGET_PUBLIC_KEY=\(publicKeys[0])")
        print("SOVAGRID_GENERATED_PROFILE_JUMP_PUBLIC_KEY=\(publicKeys[1])")
    }

    func test03DeletingLibraryKeyKeepsSavedProfilesWorking() {
        let app = XCUIApplication(bundleIdentifier: "com.sovagrid.app")
        app.launch()
        app.buttons["SSH"].tap()
        app.buttons["SSH-ключи"].tap()
        let row = app.cells.containing(.staticText, identifier: jumpName).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["Delete"].tap()
        let remove = app.buttons["Удалить ключ"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.staticTexts[jumpName])
        let result = XCTWaiter.wait(for: [absent], timeout: 5)
        if result != .completed {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "library-key-delete-diagnostic"
            shot.lifetime = .keepAlways
            add(shot)
            print("SOVAGRID_LIBRARY_DELETE_DIAGNOSTIC_BEGIN\n\(app.debugDescription)\nSOVAGRID_LIBRARY_DELETE_DIAGNOSTIC_END")
        }
        XCTAssertEqual(result, .completed)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts[profile].tap()
        let error = app.alerts["SSH-ошибка"]
        if error.waitForExistence(timeout: 3) { error.buttons["ОК"].tap() }
        app.buttons["SSH-ключи"].tap()
        let publicKeys = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 "))
            .allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(publicKeys.count, 2)
        app.buttons["Скопировать ключ перехода"].tap()
        print("SOVAGRID_GENERATED_AFTER_DELETE_TARGET_PUBLIC_KEY=\(publicKeys[0])")
        print("SOVAGRID_GENERATED_AFTER_DELETE_JUMP_PUBLIC_KEY=\(publicKeys[1])")
        print("SOVAGRID_LIBRARY_DELETE_PRESERVES_SAVED_PROFILE_KEYS")
    }

    private func create(_ app: XCUIApplication, name: String) -> String {
        type(app, field: "Название ключа, например iPhone", text: name + "\n")
        app.buttons["Создать ключ"].tap()
        let key = app.staticTexts["SSH public key"]
        XCTAssertTrue(key.waitForExistence(timeout: 10), "Public key must appear before any SSH connection")
        XCTAssertTrue(key.label.hasPrefix("ssh-ed25519 "))
        app.buttons["Скопировать открытый ключ"].tap()
        XCTAssertTrue(app.buttons["Открытый ключ скопирован"].exists)
        return key.label
    }

    private func type(_ app: XCUIApplication, field: String, text: String) {
        let input = app.textFields[field]
        input.tap()
        input.typeText(text)
    }
}
