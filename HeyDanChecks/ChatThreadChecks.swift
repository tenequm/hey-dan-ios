import XCTest

final class ChatThreadChecks: XCTestCase {
    @MainActor func testFixtureThread() throws {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1"])
        let conversation = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15))
        XCTAssertTrue(conversation.label.contains("2 unread"))
        shot("thread-list")
        conversation.tap()
        XCTAssertTrue(app.navigationBars["Taylor"].waitForExistence(timeout: 15))
        let status = app.descendants(matching: .any)["chat.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Working")
        let answer = app.buttons["Continue"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        answer.tap()
        XCTAssertTrue(app.staticTexts["chat.answer.q_0123"].waitForExistence(timeout: 10))
        shot("thread-answered")
        app.scrollViews["chat.thread"].swipeDown()
        XCTAssertTrue(app.descendants(matching: .any)["chat.message.msg_2101"].firstMatch.waitForExistence(timeout: 10))
        shot("thread-markdown")
    }

}
