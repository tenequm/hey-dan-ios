import HeyDanCore
import Testing
import UserNotifications
@testable import HeyDan

@MainActor
struct MessageNotificationTests {
    private var payload: PushPayload {
        PushPayload(
            aps: PushAPS(alert: PushAlert(title: "Taylor", body: "A reply"),
                         threadId: "conv_taylor01", mutableContent: 1, badge: 2,
                         sound: "default", category: "message"),
            hd: PushData(h: "https://app.example.com", v: 1, c: "conv_taylor01",
                         m: "msg_test", k: .message, a: Agent(id: "ag_taylor", name: "Taylor"))
        )
    }

    @Test func environmentMapping() {
        #expect(AppDelegate.environment("development") == "sandbox")
        #expect(AppDelegate.environment("production") == "production")
        #expect(AppDelegate.environment(nil) == nil)
        #expect(AppDelegate.environment("sandbox") == nil)
    }

    @Test func foregroundSuppressionRequiresHostAndConversation() {
        #expect(AppDelegate.presentation(for: payload.hd, host: payload.hd.h, conversationID: payload.hd.c).isEmpty)
        #expect(AppDelegate.presentation(for: payload.hd, host: "https://other.example", conversationID: payload.hd.c).contains(.banner))
        #expect(AppDelegate.presentation(for: payload.hd, host: payload.hd.h, conversationID: nil).contains(.badge))
        #expect(AppDelegate.presentation(for: nil, host: payload.hd.h, conversationID: payload.hd.c).contains(.banner))
    }

    @Test func intentCarriesSenderAndConversation() {
        let intent = MessageNotification.intent(for: payload)
        #expect(intent.sender?.customIdentifier == payload.hd.a.id)
        #expect(intent.sender?.personHandle?.value == payload.hd.a.id)
        #expect(intent.sender?.displayName == payload.hd.a.name)
        #expect(intent.sender?.image != nil)
        #expect(intent.conversationIdentifier == payload.hd.c)
        #expect(intent.content == payload.aps.alert.body)
    }

    @Test func contractFixtureDecodes() throws {
        let data = Data(#"{"aps":{"alert":{"title":"Taylor","body":"Done. The report is attached."},"thread-id":"conv_taylor01","mutable-content":1,"badge":3,"sound":"default","category":"message"},"hd":{"v":1,"h":"https://app.example.com","c":"conv_taylor01","m":"msg_2102","k":"message","a":{"id":"ag_taylor","name":"Taylor"}}}"#.utf8)
        let userInfo = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try #require(MessageNotification.payload(from: userInfo))
        #expect(decoded.hd.c == "conv_taylor01")
        #expect(decoded.hd.a.id == "ag_taylor")
    }

    @Test func missingRoutingDataPreservesOriginal() async throws {
        let data = try JSONEncoder().encode(payload)
        var userInfo = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        userInfo.removeValue(forKey: "hd")
        let original = UNMutableNotificationContent()
        original.title = "Original"
        original.body = "Preserved"
        original.userInfo = userInfo
        let result = await MessageNotification.content(for: original)
        #expect(result === original)
    }

    @Test func missingHostPreservesOriginal() async throws {
        let data = try JSONEncoder().encode(payload)
        var userInfo = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var hd = try #require(userInfo["hd"] as? [String: Any])
        hd.removeValue(forKey: "h")
        userInfo["hd"] = hd
        let original = UNMutableNotificationContent()
        original.userInfo = userInfo
        let result = await MessageNotification.content(for: original)
        #expect(result === original)
    }
}
