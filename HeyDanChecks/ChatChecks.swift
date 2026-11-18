import XCTest

@MainActor
final class ChatChecks: XCTestCase {
    private let app = XCUIApplication()
    private let env = ProcessInfo.processInfo.environment

    private func launch(_ extra: [String: String] = [:]) {
        continueAfterFailure = false
        app.launchEnvironment = extra
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func conversation() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.conversation.")).firstMatch
    }

    private func openThread() {
        let row = conversation()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 15))
    }

    private func stack() throws {
        guard env["HEYDAN_CHAT_STACK"] == "1" else {
            throw XCTSkip("No local stack is running: HEYDAN_LOCAL_BASE and HEYDAN_PAIR_CMD are required")
        }
    }

    private func send(_ command: String) throws {
        let text = app.textFields["composer.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        text.typeText(command)
        let send = app.buttons["composer.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    private func rows(containing text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.", text))
    }

    func testFixtureUnreadRelaunch() {
        launch(["HEYDAN_FIXTURE_CHAT": "1"])
        let row = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.label.contains("2 unread"))
        app.terminate()
        launch(["HEYDAN_FIXTURE_CHAT": "1"])
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.label.contains("2 unread"))
        XCTAssertEqual(app.buttons.matching(identifier: "chat.conversation.conv_taylor01").count, 1)
    }

    func testPairedList() throws {
        try stack()
        launch()
        XCTAssertTrue(conversation().waitForExistence(timeout: 20))
    }

    func testPastePair() throws {
        try stack()
        launch()
        openThread()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.buttons["Pair a host"].tap()
        let paste = app.buttons["pairing.paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        paste.tap()
        let allow = app.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        app.buttons["pairing.submit"].tap()
        XCTAssertTrue(app.staticTexts["Paired"].waitForExistence(timeout: 20))
    }

    func testSendReply() throws {
        try stack()
        launch()
        openThread()
        let marker = "reply " + UUID().uuidString
        try send(marker)
        XCTAssertTrue(rows(containing: marker).firstMatch.waitForExistence(timeout: 30))
        let reached = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "chat.message.", marker, "Reached")).firstMatch
        XCTAssertTrue(reached.waitForExistence(timeout: 45))
        // A routed copy can be coalesced with reached before the screen renders.
        let reply = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND NOT label CONTAINS %@",
            "chat.message.", marker, "Reached")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 45))
    }

    func testResumeAfterRelaunch() throws {
        try stack()
        launch()
        openThread()
        let ids = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat.message.")).allElementsBoundByIndex.map(\.identifier)
        XCTAssertFalse(ids.isEmpty)
        app.terminate()
        launch()
        openThread()
        for id in Set(ids) {
            let matches = app.descendants(matching: .any).matching(identifier: id)
            XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 15))
            XCTAssertEqual(matches.count, 1)
        }
    }

    func testOfflineSend() throws {
        try stack()
        launch(["HEYDAN_OFFLINE_FOR": "15"])
        openThread()
        let marker = "reply " + UUID().uuidString
        try send(marker)
        let reached = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "chat.message.", marker, "Reached"))
        XCTAssertTrue(reached.firstMatch.waitForExistence(timeout: 60))
        XCTAssertEqual(reached.count, 1)
    }

    func testQuestion() throws {
        try stack()
        launch()
        openThread()
        try send("question")
        let card = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat.question.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45))
        let answer = card.buttons.firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        answer.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat.answer.")).firstMatch.waitForExistence(timeout: 20))
    }

    func testWorkingStatus() throws {
        try stack()
        launch()
        openThread()
        try send("long")
        let status = app.descendants(matching: .any)["chat.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.waitForNonExistence(timeout: 60))
    }

    func testHistory() throws {
        try stack()
        launch()
        openThread()
        app.scrollViews["chat.thread"].swipeDown()
        let older = app.buttons["Load older messages"]
        guard older.waitForExistence(timeout: 5) else {
            throw XCTSkip("Stack conversation needs more than one page of history")
        }
        let messages = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat.message."))
        let before = Set(messages.allElementsBoundByIndex.map(\.identifier))
        older.tap()
        let newRow = messages.matching(NSPredicate(format: "NOT identifier IN %@", Array(before))).firstMatch
        XCTAssertTrue(newRow.waitForExistence(timeout: 15))
        app.scrollViews["chat.thread"].swipeUp()
        XCTAssertTrue(app.scrollViews["chat.thread"].exists)
    }

    func testDownloadFiles() throws {
        try stack()
        launch()
        openThread()
        try send("file")
        let files = app.buttons.matching(identifier: "attachment.open")
        XCTAssertTrue(files.firstMatch.waitForExistence(timeout: 45))
        XCTAssertGreaterThanOrEqual(files.count, 2)
        for index in 0..<2 {
            files.element(boundBy: index).tap()
            let done = app.buttons["Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 15))
            done.tap()
        }
    }

    func testUnreadRelaunch() throws {
        try stack()
        launch()
        let row = conversation()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let label = row.label
        guard label.contains("unread") else { throw XCTSkip("Stack must seed an unread conversation") }
        app.terminate()
        launch()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertEqual(row.label, label)
    }
    private func requestPush(conversationID: String) throws {
        guard let directory = env["HEYDAN_CHAT_CONTROL"] else {
            throw XCTSkip("Push driver is not configured")
        }
        let root = URL(fileURLWithPath: directory)
        let data = try JSONSerialization.data(withJSONObject: ["conversation": conversationID])
        try data.write(to: root.appendingPathComponent("push.json"), options: .atomic)
        let acknowledged = root.appendingPathComponent("pushed").path
        let predicate = NSPredicate { _, _ in FileManager.default.fileExists(atPath: acknowledged) }
        let done = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 15), .completed)
    }

    private var banner: XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "New message")).firstMatch
    }

    func testPushBanner() throws {
        try stack()
        launch()
        let row = conversation()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        try requestPush(conversationID: String(row.identifier.dropFirst("chat.conversation.".count)))
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
    }

    func testPushSuppressed() throws {
        try stack()
        launch()
        let row = conversation()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let id = String(row.identifier.dropFirst("chat.conversation.".count))
        row.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 15))
        try requestPush(conversationID: id)
        XCTAssertFalse(banner.waitForExistence(timeout: 8))
    }

    func testPushTap() throws {
        try stack()
        launch()
        let row = conversation()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        try requestPush(conversationID: String(row.identifier.dropFirst("chat.conversation.".count)))
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        banner.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 15))
    }

}
