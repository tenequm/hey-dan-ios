import XCTest

final class ChatThreadChecks: XCTestCase {
    @MainActor func testFixtureThread() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HEYDAN_FIXTURE_CHAT"] = "1"
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let conversation = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15))
        XCTAssertTrue(conversation.label.contains("2 unread"))
        shot(app, "thread-list")
        conversation.tap()
        XCTAssertTrue(app.navigationBars["Taylor"].waitForExistence(timeout: 15))
        let status = app.descendants(matching: .any)["chat.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Working")
        let answer = app.buttons["Continue"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        answer.tap()
        XCTAssertTrue(app.staticTexts["chat.answer.q_0123"].waitForExistence(timeout: 10))
        shot(app, "thread-answered")
        app.scrollViews["chat.thread"].swipeDown()
        XCTAssertTrue(app.descendants(matching: .any)["chat.message.msg_2101"].firstMatch.waitForExistence(timeout: 10))
        shot(app, "thread-markdown")
    }

    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let output = ProcessInfo.processInfo.environment["HEYDAN_CHECKS_OUT"] {
            try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        }
    }
}
