import XCTest

final class ChatComposerChecks: XCTestCase {
    @MainActor private func launch(attachment: Bool = false, bytes: Int = 1024, scenario: String? = nil) throws -> XCUIApplication {
        var environment: [String: String] = [:]
        environment["HEYDAN_FIXTURE_CHAT"] = "1"
        environment["HEYDAN_FIXTURE_THREAD"] = scenario
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
        let app = try launch(scenario: "text-only")
        XCTAssertFalse(app.buttons["composer.send"].isEnabled)
        let field = app.textFields["composer.text"]
        app.buttons["composer.dictation"].tap()
        XCTAssertTrue(app.staticTexts["Tap the microphone on your keyboard to dictate."].waitForExistence(timeout: 5))
        field.typeText("Composer fixture")
        XCTAssertTrue(app.staticTexts["Tap the microphone on your keyboard to dictate."].waitForNonExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["composer.record"].exists)
    }

    @MainActor func testVoiceMessage() throws {
        let app = try launch()
        let mic = app.buttons["composer.record"]
        let discard = app.buttons["composer.recording.discard"]
        let send = app.buttons["composer.recording.send"]
        mic.tap()
        XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        discard.tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.voice.play"].exists)

        mic.tap()
        let status = app.descendants(matching: .any).matching(identifier: "composer.recording.status")
        XCTAssertTrue(status.matching(NSPredicate(format: "value >= %@", "0:10")).firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(status.firstMatch.label, "Recording")
        send.tap()
        XCTAssertTrue(app.staticTexts["Transcribing..."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recorded fixture message."].waitForExistence(timeout: 15))
        let play = app.buttons["chat.voice.play"]
        XCTAssertTrue(play.exists)
        play.tap()
        XCTAssertTrue(play.wait(for: \.label, toEqual: "Pause voice message", timeout: 5))
        play.tap()
        XCTAssertEqual(play.label, "Play voice message")
        play.tap()
        XCTAssertTrue(play.wait(for: \.label, toEqual: "Pause voice message", timeout: 5))
    }

    @MainActor func testBackgroundStagesVoiceMessage() throws {
        let app = try launch()
        app.buttons["composer.record"].tap()
        let status = app.descendants(matching: .any).matching(identifier: "composer.recording.status")
        XCTAssertTrue(status.matching(NSPredicate(format: "value >= %@", "0:02")).firstMatch.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        let remove = app.buttons["composer.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recording stopped. Send or remove your voice message."].exists)
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
        XCTAssertFalse(app.buttons["chat.voice.play"].exists)
        remove.tap()
        XCTAssertTrue(app.buttons["composer.record"].waitForExistence(timeout: 5))
        XCTAssertFalse(remove.exists)
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
