import AppIntentsTesting
import XCTest

@MainActor
final class ChatChecks: XCTestCase {
    private let app = XCUIApplication()
    private let env = ProcessInfo.processInfo.environment

    private func launch(_ extra: [String: String] = [:]) {
        continueAfterFailure = false
        app.launchEnvironment = ["HEYDAN_CHAT_CHECKS": "1"].merging(extra) { _, new in new }
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
        allowPaste(in: app)
        let submit = app.buttons["pairing.submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        let chats = app.buttons["Open chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 20))
        shot("pairing-success")
        chats.tap()
        XCTAssertTrue(conversation().waitForExistence(timeout: 15))
    }

    func testPairedVoicePicker() throws {
        try stack()
        launch()
        XCTAssertTrue(conversation().waitForExistence(timeout: 20))
        app.buttons["Settings"].tap()
        let voice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Voice: ")).firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        voice.tap()
        XCTAssertTrue(app.buttons["picker.voice"].waitForExistence(timeout: 20))
        shot("paired-voice-picker")
        app.buttons["picker.close"].tap()
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
    }

    func testSendReply() throws {
        try stack()
        launch()
        openThread()
        let messageRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.message."))
        let before = messageRows.allElementsBoundByIndex.map(\.identifier)
        let marker = "reply " + UUID().uuidString
        try send(marker)
        XCTAssertTrue(rows(containing: marker).firstMatch.waitForExistence(timeout: 30))
        let reached = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "chat.message.", marker, "Reached")).firstMatch
        XCTAssertTrue(reached.waitForExistence(timeout: 45))
        // A routed copy can be coalesced with reached before the screen renders.
        if env["HEYDAN_STACK_PROFILE"] != "full" {
            let reply = app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "Stand-in reply.", "Stand-in reply.")).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 45))
        }
        // A real agent's words vary: there, any second new row with text is its reply.
        let newRows = messageRows.matching(NSPredicate(format: "NOT identifier IN %@ AND label != ''", before))
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in newRows.count >= 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 45), .completed)
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
        let questions = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat.question."))
        let previous = questions.allElementsBoundByIndex.map(\.identifier)
        try send("question")
        let card = questions.matching(NSPredicate(format: "NOT identifier IN %@", previous)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45))
        let answer = card.buttons.firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let selected = answer.label
        answer.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "chat.answer.")).firstMatch.waitForExistence(timeout: 20))
        let followup = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "Selected: " + selected, "Selected: " + selected)).firstMatch
        XCTAssertTrue(followup.waitForExistence(timeout: 45))
    }

    func testPairedIntent() async throws {
        try stack()
        launch(["HEYDAN_HANGUP_AFTER": "30", "HEYDAN_PAIRED_ICE": "all"])
        XCTAssertTrue(conversation().waitForExistence(timeout: 20))
        let bundle = String(Bundle(for: ChatChecks.self).bundleIdentifier!.dropLast(".Checks".count))
        let definitions = IntentDefinitions(bundleIdentifier: bundle)
        let id = try XCTUnwrap(env["HEYDAN_CHAT_INTENT_ID"].flatMap(UUID.init(uuidString:)))
        let matches = try await definitions.entities["VoiceLineEntity"].entities(identifiers: [id])
        let agent = try XCTUnwrap(matches.first)
        let suggestions = try await definitions.entities["VoiceLineEntity"].suggestedEntities()
        XCTAssertTrue(suggestions.contains(agent))
        let intent = definitions.intents["CallLineIntent"].makeIntent(
            destination: agent, audioVisualMode: definitions.enums["CallAVMode"].makeCase("audio"))
        try await intent.run()
        try await Task.sleep(for: .seconds(40))
        app.activate()
    }

    func testUnpair() throws {
        try stack()
        launch(["HEYDAN_CHECK_REVOKED_REQUEST": "1"])
        openThread()
        app.buttons["Settings"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.settings.host.")).firstMatch.tap()
        app.buttons["Unpair"].firstMatch.tap()
        let choices = app.buttons.matching(identifier: "Unpair")
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5))
        let confirm = try XCTUnwrap(choices.allElementsBoundByIndex.first { $0.isHittable })
        confirm.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForNonExistence(timeout: 20))
        XCTAssertFalse(conversation().exists)
    }

    func testPairedCall() throws {
        try stack()
        launch(["HEYDAN_PAIRED_FEED": "1", "HEYDAN_FEED_WAV": try XCTUnwrap(env["HEYDAN_CHAT_WAV"]),
                "HEYDAN_FEED_AFTER": "12", "HEYDAN_HANGUP_AFTER": "65", "HEYDAN_PAIRED_ICE": "all"])
        openThread()
        let call = app.buttons["chat.call"]
        XCTAssertTrue(call.waitForExistence(timeout: 10))
        XCTAssertTrue(call.isEnabled)
        call.tap()
        let close = app.buttons["chat.call.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        let until = Date().addingTimeInterval(80)
        while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        close.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 10))
    }

    func testUploadPhoto() throws { try upload() }
    func testUploadDocument() throws { try upload() }

    private func upload() throws {
        try stack()
        let path = try XCTUnwrap(env["HEYDAN_CHAT_ATTACHMENT"])
        launch(["HEYDAN_FIXTURE_ATTACHMENT": path])
        openThread()
        XCTAssertTrue(app.buttons["composer.remove"].firstMatch.waitForExistence(timeout: 15))
        let marker = "reply " + UUID().uuidString
        try send(marker)
        let uploaded = rows(containing: marker).firstMatch
        XCTAssertTrue(uploaded.buttons["attachment.open"].firstMatch.waitForExistence(timeout: 45))
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
            XCTAssertTrue(app.otherElements["QLPreviewControllerView"].waitForExistence(timeout: 15))
            app.terminate()
            if index == 0 { launch(); openThread() }
        }
    }

    func testUnreadRelaunch() throws {
        try stack()
        launch()
        openThread()
        let marker = "long 8 " + UUID().uuidString
        try send(marker)
        let reached = rows(containing: marker).matching(NSPredicate(format: "label CONTAINS %@", "Reached")).firstMatch
        XCTAssertTrue(reached.waitForExistence(timeout: 30))
        app.terminate()
        launch()
        let row = conversation()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let unread = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in row.label.contains("unread") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unread], timeout: 30), .completed)
        let label = row.label
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

    func testPushReadClears() throws {
        try stack()
        launch()
        let row = conversation()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        try requestPush(conversationID: String(row.identifier.dropFirst("chat.conversation.".count)))
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        banner.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 15))
        try send("reply " + UUID().uuidString)
        let until = Date().addingTimeInterval(15)
        while Date() < until {
            app.scrollViews["chat.thread"].swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
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
