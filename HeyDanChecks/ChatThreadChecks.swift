import XCTest

final class ChatThreadChecks: XCTestCase {
    @MainActor func testScrollToEnd() {
        let session = ScreenCaptureSession()
        defer { session.finish() }
        session.openThread("full")
        let app = session.app
        let thread = app.scrollViews["chat.thread"]
        let end = app.buttons["chat.scrollToEnd"]
        let lastOption = app.buttons["Don't restore"]
        XCTAssertTrue(lastOption.isHittable)
        XCTAssertFalse(end.exists)

        thread.swipeDown(velocity: .fast)
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertFalse(lastOption.isHittable)
        let working = app.descendants(matching: .any)["chat.status"].firstMatch
        XCTAssertTrue(working.exists)
        XCTAssertEqual(working.label, "Working")
        XCTAssertTrue(end.isHittable)
        shot("thread-scroll-up")

        end.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))
        XCTAssertTrue(lastOption.isHittable)
        shot("thread-scroll-end")
    }

    @MainActor func testFollowComposerResizing() {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_THREAD": "text-only"])
        let conversation = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let field = app.textFields["composer.text"]
        let last = app.buttons["Continue"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        let feed = app.scrollViews["chat.thread"]
        let gap = feed.frame.maxY - last.frame.maxY
        XCTAssertGreaterThan(gap, 0)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(feed.frame.maxY - last.frame.maxY, gap, accuracy: 0.5)
        let height = field.frame.height
        field.typeText("Please summarize the changes in the latest backup and include the verification results for each document.")
        XCTAssertGreaterThan(field.frame.height, height)
        XCTAssertEqual(feed.frame.maxY - last.frame.maxY, gap, accuracy: 0.5)
        XCTAssertFalse(app.buttons["chat.scrollToEnd"].exists)
    }

    @MainActor func testFollowFixtureReplies() {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_THREAD": "text-only"])
        let conversation = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let field = app.textFields["composer.text"]
        field.tap()
        field.typeText("First fixture update")
        let thread = app.scrollViews["chat.thread"]
        thread.swipeDown(velocity: .fast)
        let end = app.buttons["chat.scrollToEnd"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        let earlier = app.descendants(matching: .any)["chat.message.msg_2101"].firstMatch
        let earlierY = earlier.frame.minY
        let send = app.buttons["composer.send"]
        send.tap()
        XCTAssertTrue(end.exists)
        XCTAssertEqual(earlier.frame.minY, earlierY, accuracy: 1)

        end.tap()
        let replies = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'chat.message.msg_reply_'"))
        let first = replies.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let firstID = first.identifier
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))
        field.typeText("Second fixture update")
        send.tap()
        let next = replies.matching(NSPredicate(format: "identifier != %@", firstID)).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.isHittable)
        XCTAssertFalse(end.exists)
    }

    @MainActor func testCopyMessage() throws {
        seedPasteboard("Before Copy")
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1"])
        let conversation = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15))
        conversation.tap()
        let thread = app.scrollViews["chat.thread"]
        XCTAssertTrue(thread.waitForExistence(timeout: 10))
        thread.swipeDown()
        let message = app.descendants(matching: .any)["chat.message.msg_2101"].firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let footer = app.buttons["chat.copy.msg_2101"]
        XCTAssertFalse(footer.exists)
        // "Hello" is the first word of the markdown heading.
        message.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 14)).press(forDuration: 1)
        let copy = app.descendants(matching: .any)["chat.menu.copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Selection"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["Share"].firstMatch.exists)
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        let composer = app.descendants(matching: .any)["composer.text"].firstMatch
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        composer.tap()
        let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Paste")).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let pasted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value == %@", "composer.text",
            "## Hello\n\nThis is **Taylor**.\n\n- One\n- Two\n\n```swift\nprint(42)\n```")).firstMatch
        XCTAssertTrue(pasted.waitForExistence(timeout: 5))
    }

    @MainActor func testOwnMessageMenus() throws {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1", "HEYDAN_FIXTURE_THREAD": "message-menus"])
        let conversation = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15))
        conversation.tap()
        for id in ["chat.message.msg_5", "chat.outbox.queued", "chat.outbox.failed"] {
            let row = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            let messageID = id.split(separator: ".").last!
            XCTAssertTrue(app.buttons["chat.copy.\(messageID)"].exists)
            // The one-word bubble is trailing aligned, above its delivery status.
            row.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0)).withOffset(CGVector(dx: -32, dy: 17)).press(forDuration: 1)
            let share = app.descendants(matching: .any)["chat.menu.share"].firstMatch
            XCTAssertTrue(share.waitForExistence(timeout: 5))
            let copy = app.buttons["chat.menu.copy"].firstMatch
            XCTAssertTrue(copy.exists)
            copy.tap()
            XCTAssertTrue(share.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor func testUnloadedAttachmentHasNoMessageMenu() throws {
        let app = launchChat(["HEYDAN_FIXTURE_CHAT": "1"])
        let conversation = app.buttons["chat.conversation.conv_taylor01"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15))
        conversation.tap()
        let file = app.buttons.matching(identifier: "attachment.open").matching(NSPredicate(format: "label CONTAINS %@", "Document.pdf")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.press(forDuration: 1)
        XCTAssertFalse(app.descendants(matching: .any)["chat.menu.copy"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["Selection"].firstMatch.exists)
    }

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
