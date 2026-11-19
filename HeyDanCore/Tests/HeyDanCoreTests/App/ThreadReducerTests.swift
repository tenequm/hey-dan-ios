import Foundation
import Testing
@testable import HeyDanCore

@Test func reducerMatchesStreamOracle() throws {
    let f = try coreFixtures(), stream = f["stream"] as! [String: Any]
    let expect = stream["expect"] as! [String: Any]
    var parser = SSEParser(), reducer = ThreadReducer()
    for event in try parser.feed(Data((stream["raw"] as! String).utf8)) {
        let before = reducer.cursor
        try reducer.apply(event)
        if event.kind == .status || event.kind == .badge { #expect(reducer.cursor == before) }
        if event.kind == .synchronized { #expect(reducer.cursor == Int64(expect["cursorAtSynchronized"] as! Int)) }
    }
    #expect(reducer.cursor == Int64(expect["cursorAfter"] as! Int))
    func id(_ entity: ThreadEntity) -> String {
        switch entity { case .message(let m): m.id; case .question(let q): q.id; default: "" }
    }
    #expect(reducer.thread(conversationId: "conv_taylor01").map(id) == expect["finalThreadOrder"] as! [String])
    let rows = reducer.rows(conversationId: "conv_taylor01").compactMap { row -> String? in
        if case .entity(let entity) = row { return id(entity) }; return nil
    }
    #expect(rows == expect["renderedThreadOrder"] as! [String])
    for (key, value) in expect["finalEntities"] as! [String: [String: Any]] {
        let encoded = try JSONEncoder().encode(reducer.entities[key]!)
        let actual = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for (field, expected) in value {
            if field == "reactions" { #expect((actual[field] as! [Any]).count == expected as! Int) }
            else { #expect(String(describing: actual[field]!) == String(describing: expected)) }
        }
    }
    let status = expect["finalStatus"] as! [String: Any], badge = expect["finalBadge"] as! [String: Any]
    #expect(reducer.statuses["conv_taylor01"]?.rev == Int64(status["rev"] as! Int))
    #expect(reducer.statuses["conv_taylor01"]?.state.rawValue == status["state"] as? String)
    #expect(reducer.badge?.rev == Int64(badge["rev"] as! Int))
    #expect(reducer.badge?.unreadTotal == badge["unreadTotal"] as? Int)
    let ordered = reducer.thread(conversationId: "conv_taylor01").map(id)
    if case .message(var first) = reducer.thread(conversationId: "conv_taylor01").first! {
        first.seq = reducer.cursor + 1000
        reducer.upsert(.message(first))
        #expect(reducer.thread(conversationId: "conv_taylor01").map(id) == ordered)
    } else { Issue.record("Expected first message") }
    #expect(reducer.cursor == Int64(expect["cursorAfter"] as! Int))
    let before = reducer.cursor
    reducer.upsert(try fixtureDecode(ConversationsResponse.self, f["conversations"]!))
    #expect(reducer.cursor == before)
}

@Test func restVersionsRowsAndBootstrap() throws {
    let f = try coreFixtures()
    var reducer = ThreadReducer()
    let list = try fixtureDecode(ConversationsResponse.self, f["conversations"]!)
    reducer.upsert(list)
    #expect(reducer.cursor == list.seq)
    let edits = try fixtureDecode([Message].self, (f["messages"] as! [String: Any])["editSequence"]!)
    for message in edits { #expect(reducer.upsert(.message(message)) == [message.id]) }
    #expect(reducer.entities.count == 1)
    #expect(reducer.upsert(.message(edits[0])).isEmpty)
    #expect(reducer.entities[edits[0].id] == .message(edits.last!))
    let page = try fixtureDecode(HistoryPage.self, f["historyPage"]!)
    reducer.upsert(page, conversationId: "conv_taylor01")
    #expect(reducer.hasMoreBefore["conv_taylor01"] == page.hasMoreBefore)
    #expect(reducer.cursor == list.seq)
    let request = SendRequest(clientId: "pending", text: "", fileIds: [])
    let pending = Outbox.Entry(host: URL(string: "https://example.com")!, conversationId: "conv_taylor01", request: request)
    let count = reducer.rows(conversationId: "conv_taylor01").count
    #expect(reducer.rows(conversationId: "conv_taylor01", outbox: [pending]).count == count + 1)
    var confirmed = edits.last!; confirmed.clientId = "pending"; confirmed.seq += 100
    reducer.upsert(.message(confirmed))
    #expect(reducer.rows(conversationId: "conv_taylor01", outbox: [pending]).count == count)
    let event = AppEvent(kind: .message, id: 999, data: Data("{}".utf8))
    do { try reducer.apply(event); Issue.record("Malformed event accepted") } catch {}
    #expect(reducer.cursor == list.seq)
}

@Test func futureEntitiesAndRevisionPrecedence() throws {
    var reducer = ThreadReducer()
    let unknown = ThreadEntity.unknown(.object(["kind": .string("future"), "id": .string("future"), "seq": .integer(1), "order": .integer(1), "conversationId": .string("c")]))
    reducer.upsert(unknown)
    #expect(reducer.entities.count == 1)
    #expect(reducer.rows(conversationId: "c").isEmpty)
    reducer.upsert(Status(kind: .status, conversationId: "c", rev: 2, state: .idle, label: nil, at: 1))
    reducer.upsert(Status(kind: .status, conversationId: "c", rev: 1, state: .working, label: nil, at: 100))
    #expect(reducer.statuses["c"]?.state == .idle)
    reducer.upsert(Badge(kind: .badge, rev: 2, unreadTotal: 3))
    reducer.upsert(Badge(kind: .badge, rev: 1, unreadTotal: 9))
    #expect(reducer.badge?.unreadTotal == 3)
    let changed = try reducer.apply(AppEvent(kind: Kind("future"), id: 55, data: Data("{}".utf8)))
    #expect(changed.isEmpty)
    #expect(reducer.cursor == 55)
}

@Test func hiddenEventSurvivesAnOlderResponseAndAllowsShowingAgain() throws {
    let f = try coreFixtures()
    let wire = try #require(f["hiddenEvent"] as? [String: Any])
    let event = AppEvent(kind: try fixtureDecode(Kind.self, #require(wire["kind"])),
                         id: try #require(wire["id"] as? Int64),
                         data: try JSONSerialization.data(withJSONObject: #require(wire["data"])))
    let hidden = try event.decode(Conversation.self)
    var shown = hidden
    shown.hidden = nil
    shown.seq -= 1
    var reducer = ThreadReducer()
    reducer.upsert(shown)
    #expect(try reducer.apply(event) == [shown.id])
    #expect(reducer.conversations[shown.id] == nil && reducer.cursor == hidden.seq)
    #expect(reducer.upsert(shown).isEmpty)
    #expect(reducer.conversationRecord(shown.id) == hidden)
    shown.seq = hidden.seq + 1
    reducer.upsert(shown)
    #expect(reducer.conversations[shown.id] == shown)
}
