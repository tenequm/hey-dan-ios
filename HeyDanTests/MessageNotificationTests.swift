import Foundation
import HeyDanCore
import Synchronization
import Testing
import UserNotifications
@testable import HeyDan

private final class FixtureBundle {}

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

    private func entry(_ host: String) -> Pairings.Entry {
        Pairings.Entry(host: URL(string: host)!, pairing: PairResponse(deviceId: "dev_test", userName: "Alex",
            agents: [payload.hd.a], protocol: 1, serverTime: 0), features: ["push"])
    }

    @Test func environmentMapping() {
        #expect(AppDelegate.environment("development") == "sandbox")
        #expect(AppDelegate.environment("production") == "production")
        #expect(AppDelegate.environment(nil) == nil)
        #expect(AppDelegate.environment("sandbox") == nil)
    }

    @Test func deviceTokenIsLowercaseHex() {
        #expect(AppDelegate.tokenString(Data([0x00, 0x0a, 0xff, 0x7b])) == "000aff7b")
    }

    @Test func foregroundSuppressionRequiresHostAndConversation() {
        let host = URL(string: "https://app.example.com")!
        #expect(AppDelegate.presentation(for: payload.hd, host: host, conversationID: payload.hd.c).isEmpty)
        #expect(AppDelegate.presentation(for: payload.hd, host: URL(string: "https://APP.example.com:443/")!, conversationID: payload.hd.c).isEmpty)
        #expect(AppDelegate.presentation(for: payload.hd, host: URL(string: "https://other.example")!, conversationID: payload.hd.c).contains(.banner))
        #expect(AppDelegate.presentation(for: payload.hd, host: host, conversationID: nil).contains(.badge))
        #expect(AppDelegate.presentation(for: payload.hd, host: nil, conversationID: payload.hd.c).contains(.banner))
        #expect(AppDelegate.presentation(for: nil, host: host, conversationID: payload.hd.c).contains(.banner))
    }

    @Test func tapRoutesByHostKey() {
        let entries = [entry("https://other.example.com"), entry("https://app.example.com")]
        var data = payload.hd
        #expect(AppDelegate.entry(for: data, in: entries)?.host.absoluteString == "https://app.example.com")
        data.h = "https://app.example.com/"
        #expect(AppDelegate.entry(for: data, in: entries)?.host.absoluteString == "https://app.example.com")
        data.h = "https://unknown.example.com"
        #expect(AppDelegate.entry(for: data, in: entries) == nil)
    }

    @Test func deliveredNotificationsClearOnlyWhenReadOrderRises() {
        #expect(!AppDelegate.clearsDelivered(previous: nil, readOrder: 118))
        #expect(!AppDelegate.clearsDelivered(previous: 118, readOrder: 118))
        #expect(AppDelegate.clearsDelivered(previous: 118, readOrder: 120))
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
        let url = try #require(Bundle(for: FixtureBundle.self).url(forResource: "app-contract.fixtures", withExtension: "json"))
        let fixtures = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let body = try #require((fixtures["pushPayload"] as? [String: Any])?["body"] as? [String: Any])
        let decoded = try #require(MessageNotification.payload(from: body))
        #expect(decoded.hd.c == "conv_taylor01")
        #expect(decoded.hd.a.id == "ag_taylor")
        #expect(PairedHost.key(decoded.hd.h) == "https://app.example.com")
    }

    @Test func nonJSONUserInfoIsRejected() {
        #expect(MessageNotification.payload(from: ["date": Date()]) == nil)
    }

    // A plain banner looks the same in a UI check: only the entitled app can turn it into a communication notification.
    @Test(.timeLimit(.minutes(1))) func communicationNotificationsAreEntitled() async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        #expect(settings.directMessagesSetting != .notSupported)
        let original = UNMutableNotificationContent()
        original.userInfo = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let content = await MessageNotification.content(for: payload, original: original)
        #expect(content !== original)
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

    @Test func deliveryCallsTheHandlerOnce() {
        let original = UNMutableNotificationContent()
        let replacement = UNMutableNotificationContent()
        let calls = Mutex<[UNNotificationContent]>([])
        let expired = NotificationDelivery(original: original) { content in calls.withLock { $0.append(content) } }
        expired.finish()
        expired.finish(replacement)
        let updated = NotificationDelivery(original: original) { content in calls.withLock { $0.append(content) } }
        updated.finish(replacement)
        updated.finish()
        let delivered = calls.withLock { $0 }
        #expect(delivered.count == 2)
        #expect(delivered.first === original)
        #expect(delivered.last === replacement)
    }
}
