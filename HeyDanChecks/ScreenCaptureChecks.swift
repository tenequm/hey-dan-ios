import Vision
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

    func testList() {
        let session = ScreenCaptureSession()
        defer { session.finish() }
        let app = session.app
        session.show("list", scenario: "Activity")
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(app.buttons["chat.conversation.preview-1"].label.contains("Done"))
        XCTAssertTrue(app.buttons["chat.conversation.preview-2"].label.contains("Input"))
        let working = app.buttons["chat.conversation.preview-0"]
        XCTAssertTrue(working.label.contains("Working"))
        capture("list", showing: working)
        session.show("list", scenario: "Reconnecting")
        capture("list-reconnecting", showing: app.staticTexts["Reconnecting…"])
        session.show("list", scenario: "Empty")
        capture("list-empty", showing: app.staticTexts["No agents yet"])
    }

    func testPairing() {
        let session = ScreenCaptureSession()
        defer { session.finish() }
        let app = session.app
        session.show("pairing")
        let paste = app.buttons["pairing.paste"]
        capture("pairing-empty", showing: paste)
        seedPasteboard("https://home.example.ts.net/app/pair#capture-only")
        paste.tap()
        allowPaste(in: app)
        let submit = app.buttons["pairing.submit"]
        XCTAssertTrue(submit.isEnabled)
        capture("pairing-pasted", showing: submit)
        submit.tap()
        capture("pairing-error", showing: app.staticTexts["This link was already used. Ask Dan for a new one with /pair."])
        session.show("paired")
        capture("pairing-success", showing: app.buttons["Open chats"])
    }

    func testSettings() {
        let session = ScreenCaptureSession()
        defer { session.finish() }
        let app = session.app
        session.show("chat")
        app.buttons["Settings"].tap()
        let host = app.buttons["chat.settings.host.home.example.ts.net"]
        capture("settings", showing: host)
        host.tap()
        let voice = app.buttons["Voice: Dan"]
        capture("host-detail", showing: voice)
        voice.tap()
        capture("voice-picker", showing: app.descendants(matching: .any)["picker.provider"].firstMatch)
        app.buttons["picker.close"].tap()
        let unpair = app.buttons["Unpair"]
        if !unpair.isHittable { app.swipeUp() }
        unpair.tap()
        capture("unpair-confirm", showing: app.buttons["Cancel"])
    }

    func testThread() {
        let session = ScreenCaptureSession()
        defer { session.finish() }
        let app = session.app
        for (scenario, name, id) in [
            ("full", "thread-full", "chat.message.msg_3"),
            ("attachments", "thread-attachments", "chat.message.msg_3"),
            ("summary", "thread-rich-card-summary", "chat.card.msg_card"),
            ("table", "thread-rich-card-table", "chat.card.msg_card"),
            ("spoken", "thread-after-call", "chat.message.msg_4"),
            ("failed", "thread-failed-send", "chat.message.msg_4")
        ] {
            session.openThread(scenario)
            if scenario == "full" {
                let thread = app.scrollViews["chat.thread"]
                thread.swipeDown(velocity: .fast)
            }
            capture(name, showing: app.descendants(matching: .any)[id].firstMatch)
        }
        session.openThread("history")
        capture("thread-loading-history", showing: app.buttons["Load older messages"])
        session.openThread("question")
        let answer = app.buttons["Yesterday, 02:00"].firstMatch
        capture("thread-question-open", showing: answer)
        answer.tap()
        capture("thread-question-answered", showing: app.staticTexts["chat.answer.q_snapshot"])
    }

    func testComposer() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "backup.toml")
        try Data(("[backup]\n" + String(repeating: " ", count: 2039)).utf8).write(to: file)
        let session = ScreenCaptureSession(environment: ["HEYDAN_FIXTURE_ATTACHMENT": file.path])
        defer { session.finish() }
        session.openThread("composer")
        let app = session.app
        let remove = app.buttons["composer.remove"]
        capture("thread-staged", showing: remove)
        remove.tap()
        let field = app.descendants(matching: .any)["composer.text"].firstMatch
        capture("composer-empty", showing: field)
        app.buttons["composer.attach"].tap()
        let photos = app.buttons["composer.photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        // UIKit exposes the menu to accessibility before SpringBoard's screenshot contains it.
        let deadline = Date.now.addingTimeInterval(6)
        var menuImage: XCUIScreenshot?
        repeat {
            let screenshot = XCUIScreen.main.screenshot()
            let recognize = VNRecognizeTextRequest()
            if let image = screenshot.image.cgImage {
                try VNImageRequestHandler(cgImage: image).perform([recognize])
                let labels = recognize.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                if labels.contains("Photos"), labels.contains("Files") { menuImage = screenshot }
            }
        } while menuImage == nil && Date.now < deadline
        shot("thread-attachment-menu", screenshot: try XCTUnwrap(menuImage, "Menu choices were not visible in the screenshot"))
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        field.tap()
        field.typeText("Also send me the backup log from last night, and tell Stan the key is rotated.")
        XCTAssertTrue(app.buttons["composer.send"].isEnabled)
        capture("thread-composing", showing: field)
    }

    func testCallCover() {
        let session = ScreenCaptureSession()
        defer { session.finish() }
        for phase in ["connecting", "speaking", "failed", "listening", "thinking", "muted", "reconnecting"] {
            session.show("call", phase: phase)
            capture(phase == "speaking" ? "call-live" : "call-" + phase, showing: session.app.buttons["chat.call.close"])
            if phase == "speaking" {
                session.app.buttons["controls.options"].tap()
                capture("call-options", showing: session.app.switches["options.typing"].firstMatch)
                session.app.buttons["Close"].firstMatch.tap()
            }
        }
    }

    func testLockScreenNotification() {
        let session = ScreenCaptureSession(environment: ["HEYDAN_DEBUG_NOTIFY": "conv_dan"])
        defer { session.finish() }
        session.show("chat")
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        defer { XCUIDevice.shared.press(.home); XCUIDevice.shared.press(.home) }
        let notice = system.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Backup is green again")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 25))
        shot("push-lock-screen")
    }
}

@MainActor final class ScreenCaptureSession {
    let app: XCUIApplication
    private let request = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    init(environment: [String: String] = [:], paired: Bool = true) {
        app = XCUIApplication()
        app.launchEnvironment = environment
        app.launchEnvironment["HEYDAN_CAPTURE_REQUEST"] = request.path
        app.launchEnvironment["HEYDAN_CAPTURE_PHOTO"] = Bundle(for: ScreenCaptureChecks.self).url(forResource: "backup-nas", withExtension: "png")?.path
        if paired { app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1" }
        app.launchForChecks()
    }

    func show(_ family: String, scenario: String? = nil, phase: String? = nil) {
        let id = UUID().uuidString
        let fields = ["id": id, "family": family, "scenario": scenario, "phase": phase]
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
        let row = app.buttons["chat.conversation.conv_dan"]
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
