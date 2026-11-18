import XCTest

final class ChatComposerChecks: XCTestCase {
    @MainActor private func launch(attachment: Bool = false, bytes: Int = 1024) throws -> XCUIApplication {
        var environment: [String: String] = [:]
        environment["HEYDAN_FIXTURE_CHAT"] = "1"
        environment["HEYDAN_COMPOSER_CHECKS"] = "1"
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
        field.tap()
        field.typeText("Composer fixture")
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.staticTexts["reached"].waitForExistence(timeout: 15))
        XCTAssertEqual(field.value as? String, "Message")
    }

    @MainActor func testStagedFileSend() throws {
        let app = try launch(attachment: true)
        XCTAssertTrue(app.buttons["composer.remove"].waitForExistence(timeout: 10))
        app.buttons["composer.send"].tap()
        XCTAssertTrue(app.staticTexts["reached"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["composer.remove"].exists)
        XCTAssertTrue(app.progressIndicators["composer.fixture.progress"].exists)
    }

    @MainActor func testRefusedSendKeepsDraftAndTray() throws {
        let app = try launch(attachment: true, bytes: 26 * 1024 * 1024)
        XCTAssertTrue(app.buttons["composer.remove"].waitForExistence(timeout: 10))
        let field = app.textFields["composer.text"]
        field.tap()
        field.typeText("Keep draft")
        app.buttons["composer.send"].tap()
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: app.buttons["composer.send"])
        waitForExpectations(timeout: 10)
        XCTAssertEqual(field.value as? String, "Keep draft")
        XCTAssertTrue(app.buttons["composer.remove"].exists)
        XCTAssertFalse(app.staticTexts["reached"].exists)
    }

    @MainActor func testFixtureImageAndPDFOpen() throws {
        for name in ["Image.png", "Document.pdf"] {
            let app = try launch()
            if name == "Document.pdf" { app.scrollViews["composer.fixture.rows"].swipeUp() }
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
