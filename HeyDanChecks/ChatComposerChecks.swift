import XCTest

final class ChatComposerChecks: XCTestCase {
    @MainActor private func launch(attachment: Bool = false, bytes: Int = 1024) throws -> XCUIApplication {
        var environment: [String: String] = [:]
        environment["HEYDAN_FIXTURE_CHAT"] = "1"
        if attachment {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("composer-check.txt")
            try Data(repeating: 65, count: bytes).write(to: url)
            environment["HEYDAN_FIXTURE_ATTACHMENT"] = url.path
        }
        let app = launchChat(environment)
        XCTAssertTrue(app.buttons["chat.conversation.conv_taylor01"].waitForExistence(timeout: 15))
        app.buttons["chat.conversation.conv_taylor01"].tap()
        XCTAssertTrue(app.textFields["composer.text"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor func testTextSend() throws {
        let app = try launch()
        XCTAssertFalse(app.buttons["composer.send"].isEnabled)
        let field = app.textFields["composer.text"]
        app.buttons["composer.dictation"].tap()
        XCTAssertTrue(app.staticTexts["Tap the microphone on your keyboard to dictate."].waitForExistence(timeout: 5))
        field.typeText("Composer fixture")
        XCTAssertFalse(app.staticTexts["Tap the microphone on your keyboard to dictate."].exists)
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.message.' AND label CONTAINS %@ AND label CONTAINS 'Reached'", "Composer fixture")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, "Message")
    }

    @MainActor func testStagedFileSend() throws {
        let app = try launch(attachment: true)
        XCTAssertTrue(app.buttons["composer.remove"].waitForExistence(timeout: 10))
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.message.' AND label CONTAINS %@ AND label CONTAINS 'Reached'", "composer-check.txt")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["composer.remove"].exists)
    }

    @MainActor func testOversizedPickShowsLimitWithoutStaging() throws {
        let app = try launch(attachment: true, bytes: 25 * 1024 * 1024 + 1)
        XCTAssertTrue(app.staticTexts["Files must be at most 25 MiB."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["composer.remove"].exists)
        XCTAssertFalse(app.buttons["composer.send"].isEnabled)
    }

    @MainActor func testFixtureImageAndPDFOpen() throws {
        for name in ["Image.png", "Document.pdf"] {
            let app = try launch()
            if name == "Document.pdf" { app.scrollViews["chat.thread"].swipeUp() }
            let button = app.buttons.matching(identifier: "attachment.open").matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    @MainActor func testPhotosPicker() throws {
        let app = try launch()
        app.buttons["composer.attach"].tap()
        app.buttons["composer.photos"].tap()
        let photo = app.images.matching(NSPredicate(format: "label CONTAINS 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        let add = app.buttons["Add"]
        if add.waitForExistence(timeout: 3) { add.tap() }
        XCTAssertTrue(app.buttons["composer.remove"].waitForExistence(timeout: 15))
    }
}
