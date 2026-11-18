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

    @MainActor func testRichCardSummary() throws {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1"])
        let card = openFixtureCard(in: app)
        XCTAssertTrue(card.staticTexts["Backup report"].exists)
        XCTAssertTrue(card.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "1.2 TB")).firstMatch.exists)
        XCTAssertTrue(card.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Open report")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Backup report: Green, 1.2 TB, 48 min."].exists)
        shot("thread-rich-card-summary")
    }

    @MainActor func testRichCardTable() throws {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_CARD": "table"])
        let card = openFixtureCard(in: app)
        let table = card.scrollViews.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let header = table.staticTexts["Files"]
        let before = header.frame.minX
        table.swipeLeft()
        XCTAssertLessThan(header.frame.minX, before)
        XCTAssertTrue(card.staticTexts["Duration, minutes"].exists)
        table.swipeRight()
        shot("thread-rich-card-table")
    }

    @MainActor private func openFixtureCard(in app: XCUIApplication) -> XCUIElement {
        let conversation = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15))
        conversation.tap()
        let card = app.descendants(matching: .any)["chat.card.msg_card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        return card
    }

    @MainActor func testListActivityStates() {
        let app = launchChat(["HEYDAN_GALLERY": "List/Activity"])
        let working = app.buttons["chat.conversation.preview-0"]
        XCTAssertTrue(working.waitForExistence(timeout: 10))
        XCTAssertTrue(working.label.contains("Working"))
        XCTAssertTrue(app.buttons["chat.conversation.preview-1"].label.contains("Done"))
        XCTAssertTrue(app.buttons["chat.conversation.preview-2"].label.contains("Input"))
        shot("activity-list")
        shot("activity-row", screenshot: working.screenshot())
    }
}
