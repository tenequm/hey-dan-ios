import XCTest

@MainActor final class ScreenCaptureChecks: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HEYDAN_SCREENS"] == "1")
        continueAfterFailure = false
    }

    private func capture(_ name: String, showing element: XCUIElement) {
        XCTAssertTrue(element.exists || element.waitForExistence(timeout: 15), "Missing screen: \(name)")
        // Informational views, including the call-refusal banner, can be visible without a hit target.
        XCTAssertFalse(element.frame.intersection(XCUIApplication().frame).isEmpty, "Offscreen: \(name)")
        shot(name)
    }

    func testChatScreens() {
        let session = ScreenCaptureSession(environment: ["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_CALL_REFUSAL": "1"])
        defer { session.finish() }
        let app = session.app
        let row = app.buttons["chat.conversation.conv_taylor01"]
        session.show("chat", scenario: "offline")
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        capture("list-empty-offline", showing: app.staticTexts["No conversations"])
        session.show("chat")
        capture("list-unread", showing: row)
        row.tap()
        capture("thread-call-refused", showing: app.staticTexts["chat.call.refusal"])
        app.buttons["Settings"].tap()
        capture("settings-paired", showing: app.staticTexts["Taylor tester"])
        app.buttons["Voice: Taylor"].tap()
        capture("voice-paired-unavailable", showing: app.buttons["picker.retry"])
        app.buttons["picker.close"].tap()
        app.buttons["Unpair"].tap()
        capture("settings-unpair", showing: app.staticTexts["Unpair this host?"])
        session.openThread()
        app.buttons["Settings"].tap()
        app.buttons["Pair a host"].tap()
        capture("pairing-sheet", showing: app.textFields["pairing.link"])
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
        let session = ScreenCaptureSession(environment: ["HEYDAN_FIXTURE_CHAT": "1"])
        defer { session.finish() }
        let app = session.app
        session.openThread()
        let answer = app.buttons["Continue"]
        capture("question-open", showing: answer)
        answer.tap()
        capture("question-answered", showing: app.staticTexts["chat.answer.q_0123"])
        app.scrollViews["chat.thread"].swipeDown()
        capture("thread-markdown", showing: app.descendants(matching: .any)["chat.message.msg_2101"].firstMatch)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        capture("list-read", showing: app.buttons["chat.conversation.conv_taylor01"])
        session.openThread("messages")
        let thread = app.scrollViews["chat.thread"]
        capture("thread-waiting", showing: app.descendants(matching: .any)["chat.status"].firstMatch)
        capture("question-expired", showing: app.descendants(matching: .any)["chat.question.q_2110"].firstMatch)
        thread.swipeDown()
        for (id, name) in [("msg_0126", "edited-reaction"), ("msg_2107", "caller"), ("msg_2108", "spoken"), ("msg_2109", "host")] {
            let row = app.descendants(matching: .any)["chat.message.\(id)"].firstMatch
            if !row.isHittable { thread.swipeUp() }
            capture("thread-\(name)", showing: row)
        }

        session.openThread("delivery")
        for (id, name) in [("msg_2113", "failed"), ("msg_2105", "unknown"), ("msg_2103", "reached-with-file")] {
            let row = app.descendants(matching: .any)["chat.message.\(id)"].firstMatch
            if !row.isHittable { app.scrollViews["chat.thread"].swipeDown() }
            capture("delivery-\(name)", showing: row)
        }

        session.openThread("outbox")
        for state in ["Held", "Waiting to retry", "Queued", "Routed", "Stored"] {
            let row = thread.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", state)).firstMatch
            if !row.isHittable { thread.swipeDown() }
            capture("outbox-" + state.lowercased().replacingOccurrences(of: " ", with: "-"), showing: row)
        }

        session.openThread("answer-error")
        app.buttons["Continue"].tap()
        let card = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "The answer did not reach the agent")).firstMatch
        capture("question-error", showing: card)
    }

    func testComposer() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appendingPathComponent("Notes.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = ScreenCaptureSession(environment: ["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_ATTACHMENT": url.path])
        defer { session.finish() }
        let app = session.app
        session.openThread("text-only")
        XCTAssertFalse(app.buttons["composer.attach"].exists)
        capture("composer-text-only", showing: app.textFields["composer.text"])
        session.openThread()
        capture("composer-import-error", showing: app.staticTexts["Could not read the selected attachment. Try selecting it again."])
        try Data("Meeting notes".utf8).write(to: url)
        session.openThread()
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
        let session = ScreenCaptureSession(environment: ["HEYDAN_FIXTURE_CHAT": "1"])
        defer { session.finish() }
        let app = session.app
        for (name, file) in [("image", "Image.png"), ("pdf", "Document.pdf")] {
            session.openThread()
            if name == "pdf" { app.scrollViews["chat.thread"].swipeUp() }
            let attachment = app.buttons.matching(identifier: "attachment.open")
                .matching(NSPredicate(format: "label CONTAINS %@", file)).firstMatch
            capture("thread-attachment-\(name)", showing: attachment)
            attachment.tap()
            capture("preview-\(name)", showing: app.otherElements["QLPreviewControllerView"])
        }
    }

    func testCallCover() {
        let phases = ["idle", "connecting", "listening", "waiting", "thinking", "speaking", "muted",
                      "thinking-muted", "speaking-muted", "reconnecting", "ended", "left", "failed",
                      "manual", "recording", "finishing", "draft", "notsent", "toolong", "manual-speaking", "kept"]
        let session = ScreenCaptureSession(environment: ["HEYDAN_FIXTURE_CHAT": "1"])
        defer { session.finish() }
        for phase in phases {
            session.show("call", phase: phase)
            capture("call-\(phase)", showing: session.app.buttons["chat.call.close"])
        }
    }

    func testLineSettings() {
        let app = launchChat(["HEYDAN_PREVIEW_PHASE": "idle", "HEYDAN_PREVIEW_LINES": "Taylor",
                              "HEYDAN_PREVIEW_SETTINGS": "1"])
        capture("settings-lines", showing: app.buttons["close"])
    }
}

@MainActor final class ScreenCaptureSession {
    let app: XCUIApplication
    private let request = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    init(environment: [String: String]) {
        app = XCUIApplication()
        app.launchEnvironment = environment.merging(["HEYDAN_CAPTURE_REQUEST": request.path]) { $1 }
        app.launch()
    }

    func show(_ family: String, scenario: String? = nil, phase: String? = nil, voice: String? = nil) {
        let id = UUID().uuidString
        let fields = ["id": id, "family": family, "scenario": scenario, "phase": phase, "voice": voice]
        XCTAssertNoThrow(try JSONEncoder().encode(fields).write(to: request, options: .atomic))
        let ready = request.appendingPathExtension("ready")
        let deadline = Date.now.addingTimeInterval(10)
        while (try? String(contentsOf: ready, encoding: .utf8)) != id {
            guard Date.now < deadline else {
                XCTFail("Missing fixture: \(family)/\(scenario ?? phase ?? "default")")
                return
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
    }

    func openThread(_ scenario: String? = nil) {
        show("chat", scenario: scenario)
        let row = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(row.exists || row.waitForExistence(timeout: 15))
        row.tap()
        XCTAssertTrue(app.scrollViews["chat.thread"].waitForExistence(timeout: 10))
    }

    func finish() {
        app.terminate()
        try? FileManager.default.removeItem(at: request)
        try? FileManager.default.removeItem(at: request.appendingPathExtension("ready"))
    }
}
