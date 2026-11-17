import HeyDanCore
import Observation
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var synchronizing = false
    private var synchronizeAgain = false
    private var token: String?
    private var uploaded: [String: String] = [:]
    private var pendingTap: PushData?
    private var reads: [String: Int64] = [:]
    private var lastBadge: String?
    private var registered = false
    private var invalidEnvironmentLogged = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "message", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "New message", options: [])])
        Task {
            for await _ in Observations({ (Pairings.shared.entries, Pairings.shared.state) }) {
                await synchronizePairings()
                routePendingTap()
            }
        }
        Task {
            for await _ in Observations({ (ChatController.shared.badge, ChatController.shared.conversations, Pairings.shared.active?.host) }) {
                await synchronizeReadState()
            }
        }
        Task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                await synchronizePairings()
            }
        }
        #if DEBUG
        Task { await debugNotification() }
        #endif
        return true
    }

    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .badge, .sound]) }
            catch { CallLog.log(.net, "push permission_failed") }
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func environment(_ value: String?) -> String? {
        switch value { case "development": "sandbox"; case "production": "production"; default: nil }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await synchronizePairings() }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        CallLog.log(.net, "push registration_failed")
    }

    private func synchronizePairings() async {
        guard !synchronizing else { synchronizeAgain = true; return }
        synchronizing = true
        defer {
            synchronizing = false
            if synchronizeAgain {
                synchronizeAgain = false
                Task { await synchronizePairings() }
            }
        }
        let entries = Pairings.shared.entries
        if !entries.isEmpty, !registered {
            registered = true
            UIApplication.shared.registerForRemoteNotifications()
        }
        let hosts = Set(entries.map { $0.host.absoluteString })
        uploaded = uploaded.filter { hosts.contains($0.key) }
        guard let token else { return }
        guard let environment = Self.environment(Bundle.main.object(forInfoDictionaryKey: "HeyDanAPSEnvironment") as? String) else {
            if !invalidEnvironmentLogged { CallLog.log(.net, "push invalid_environment"); invalidEnvironmentLogged = true }
            return
        }
        #if DEBUG
        if Pairings.shared.isFixture { return }
        #endif
        for entry in entries where entry.features.contains("push") {
            let key = entry.host.absoluteString
            let value = entry.deviceId + ":" + environment + ":" + token
            guard uploaded[key] != value else { continue }
            do {
                try await SignedClient(host: entry.host, deviceId: entry.deviceId).registerPushToken(PushTokenRequest(token: token, environment: environment))
                uploaded[key] = value
            } catch { CallLog.log(.net, "push upload_failed") }
        }
    }

    static func presentation(for data: PushData?, host: String?, conversationID: String?) -> UNNotificationPresentationOptions {
        if let data, data.h == host, data.c == conversationID { return [] }
        return [.banner, .list, .sound, .badge]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let data = MessageNotification.payload(from: notification.request.content.userInfo)?.hd
        return await Self.presentation(for: data, host: Pairings.shared.active?.host.absoluteString, conversationID: ChatController.shared.openConversationId)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let data = MessageNotification.payload(from: response.notification.request.content.userInfo)?.hd
        Task { @MainActor in
            receiveTap(data)
            // UIKit updates state restoration from this completion on the main thread.
            completionHandler()
        }
    }
    private func receiveTap(_ data: PushData?) {
        pendingTap = data
        if data == nil { ChatController.shared.closeConversation() }
        routePendingTap()
    }
    private func routePendingTap() {
        guard Pairings.shared.state != .unreadable, let data = pendingTap else { return }
        pendingTap = nil
        guard let entry = Pairings.shared.entries.first(where: { $0.host.absoluteString == data.h }) else {
            ChatController.shared.closeConversation()
            return
        }
        do {
            try Pairings.shared.setActive(host: entry.host)
            let chat = ChatController.shared
            chat.openConversation(data.c)
            let generation = chat.generation
            Task {
                await chat.loadTask?.value
                guard chat.generation == generation, chat.openConversationId == data.c else { return }
                await chat.loadHistory()
            }
        } catch { CallLog.log(.net, "push routing_failed") }
    }

    private func synchronizeReadState() async {
        guard let active = Pairings.shared.active else { return }
        let host = active.host.absoluteString
        let identity = host + ":" + active.deviceId
        let chat = ChatController.shared
        let center = UNUserNotificationCenter.current()
        let conversations = chat.conversations
        if let badge = chat.badge {
            let value = "\(identity):\(badge.rev):\(badge.unreadTotal)"
            if lastBadge != value {
                do { try await center.setBadgeCount(badge.unreadTotal); lastBadge = value }
                catch { CallLog.log(.net, "push badge_failed") }
            }
        }
        for conversation in conversations {
            let key = identity + ":" + conversation.id
            let previous = reads[key] ?? 0
            reads[key] = max(previous, conversation.readOrder)
            guard conversation.readOrder > previous else { continue }
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter {
                $0.request.content.threadIdentifier == conversation.id && MessageNotification.payload(from: $0.request.content.userInfo)?.hd.h == host
            }.map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    #if DEBUG
    private func debugNotification() async {
        guard let id = ProcessInfo.processInfo.environment["HEYDAN_DEBUG_NOTIFY"] else { return }
        try? await Task.sleep(for: .seconds(8))
        guard let entry = Pairings.shared.active, let agent = entry.agents.first else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        CallLog.log(.net, "push directMessagesSetting=\(settings.directMessagesSetting.rawValue) environment=\(Bundle.main.object(forInfoDictionaryKey: "HeyDanAPSEnvironment") as? String ?? "missing")")
        let payload = PushPayload(aps: PushAPS(alert: PushAlert(title: agent.name, body: "New message"), threadId: id, mutableContent: 1, badge: 1, sound: "default", category: "message"), hd: PushData(h: entry.host.absoluteString, v: 1, c: id, m: "debug_message", k: .message, a: agent))
        let original = UNMutableNotificationContent()
        original.title = payload.aps.alert.title
        original.body = payload.aps.alert.body
        original.threadIdentifier = id
        original.categoryIdentifier = "message"
        original.sound = .default
        do {
            original.userInfo = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
            let content = await MessageNotification.content(for: payload, original: original)
            try await center.add(UNNotificationRequest(identifier: "h5-debug", content: content, trigger: nil))
        } catch { CallLog.log(.net, "push debug_failed") }
    }
    #endif
}
