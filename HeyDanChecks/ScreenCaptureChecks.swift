import XCTest

@MainActor final class ScreenCaptureChecks: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDAN_SCREENS"] == "1")
        continueAfterFailure = false
    }

    private func capture(_ name: String, showing element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), "Missing screen: \(name)")
        XCTAssertTrue(element.isHittable, "Offscreen: \(name)")
        shot(name)
    }

    private func openThread(_ environment: [String: String] = [:]) -> XCUIApplication {
        let app = launchChat(environment.merging(["HEYDAN_FIXTURE_CHAT": "1"]) { $1 })
        let row = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 10))
        return app
    }

    func testConversationsAndSettings() {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_CALL_REFUSAL": "1"])
        let row = app.buttons["chat.conversation.conv_taylor01"]
        capture("list-unread", showing: row)
        row.tap()
        capture("thread-call-refused", showing: app.staticTexts["chat.call.refusal"])
        app.buttons["Settings"].tap()
        capture("settings-paired", showing: app.staticTexts["Taylor tester"])
        app.buttons["Pair a host"].tap()
        capture("pairing-sheet", showing: app.textFields["pairing.link"])
    }

    func testOfflineList() {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_OFFLINE_FOR": "120"])
        capture("list-empty-offline", showing: app.staticTexts["No conversations"])
    }

    func testPairing() {
        let app = launchChat(["HEYDAN_SHOW_PAIRING": "1", "HEYDAN_OFFLINE_FOR": "120"])
        let link = app.textFields["pairing.link"]
        capture("pairing", showing: link)
        link.tap()
        link.typeText("invalid")
        app.buttons["pairing.submit"].tap()
        capture("pairing-invalid", showing: app.staticTexts["Paste a valid pairing link."])
    }

    func testThread() {
        let app = openThread()
        let answer = app.buttons["Continue"]
        capture("question-open", showing: answer)
        answer.tap()
        capture("question-answered", showing: app.staticTexts["chat.answer.q_0123"])
        app.scrollViews["chat.thread"].swipeDown()
        capture("thread-markdown", showing: app.descendants(matching: .any)["chat.message.msg_2101"].firstMatch)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        capture("list-read", showing: app.buttons["chat.conversation.conv_taylor01"])
    }

    func testMessageKinds() {
        let app = openThread(["HEYDAN_FIXTURE_THREAD": "messages"])
        let thread = app.scrollViews["chat.thread"]
        capture("question-expired", showing: app.descendants(matching: .any)["chat.question.q_2110"].firstMatch)
        thread.swipeDown()
        for (id, name) in [("msg_0126", "edited-reaction"), ("msg_2107", "caller"), ("msg_2108", "spoken"), ("msg_2109", "host")] {
            let row = app.descendants(matching: .any)["chat.message.\(id)"].firstMatch
            if !row.isHittable { thread.swipeUp() }
            capture("thread-\(name)", showing: row)
        }
    }

    func testDelivery() {
        let app = openThread(["HEYDAN_FIXTURE_THREAD": "delivery"])
        for (id, name) in [("msg_2113", "failed"), ("msg_2105", "unknown"), ("msg_2103", "reached-with-file")] {
            let row = app.descendants(matching: .any)["chat.message.\(id)"].firstMatch
            if !row.isHittable { app.scrollViews["chat.thread"].swipeDown() }
            capture("delivery-\(name)", showing: row)
        }
    }

    func testComposer() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Notes.txt")
        try Data("Meeting notes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let app = openThread(["HEYDAN_FIXTURE_ATTACHMENT": url.path])
        let remove = app.buttons["composer.remove"]
        capture("composer-attachment", showing: remove)
        remove.tap()
        let field = app.textFields["composer.text"]
        capture("composer-empty", showing: field)
        field.tap()
        field.typeText("Ready for review")
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
        capture("composer-draft", showing: field)
        app.buttons["composer.attach"].tap()
        capture("composer-attachment-menu", showing: app.buttons["composer.photos"])
    }

    func testPreviews() {
        for (name, file) in [("image", "Image.png"), ("pdf", "Document.pdf")] {
            let app = openThread()
            if name == "pdf" { app.scrollViews["chat.thread"].swipeUp() }
            let attachment = app.buttons.matching(identifier: "attachment.open")
                .matching(NSPredicate(format: "label CONTAINS %@", file)).firstMatch
            capture("thread-attachment-\(name)", showing: attachment)
            attachment.tap()
            capture("preview-\(name)", showing: app.otherElements["QLPreviewControllerView"])
            app.terminate()
        }
    }

    func testCallCover() {
        let phases = ["idle", "connecting", "listening", "waiting", "thinking", "speaking", "muted",
                      "thinking-muted", "speaking-muted", "reconnecting", "ended", "left", "failed",
                      "manual", "recording", "finishing", "draft", "notsent", "toolong", "manual-speaking", "kept"]
        for phase in phases {
            let app = XCUIApplication()
            app.launchEnvironment = ["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_PREVIEW_PHASE": phase]
            app.launch()
            capture("call-\(phase)", showing: app.buttons["chat.call.close"])
            app.terminate()
        }
    }

    func testLineSettings() {
        let app = launchChat(["HEYDAN_PREVIEW_PHASE": "idle", "HEYDAN_PREVIEW_LINES": "Taylor",
                              "HEYDAN_PREVIEW_SETTINGS": "1"])
        capture("settings-lines", showing: app.buttons["close"])
    }
}
