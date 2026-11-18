import HeyDanCore
import Observation
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let apsEnvironmentKey = "HeyDanAPSEnvironment"
    private static var permissionRequested = false
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
            // A reconnect retries an upload that failed while the app stayed open.
            for await _ in Observations({ (Pairings.shared.entries, Pairings.shared.state, ChatController.shared.connectionState == .connected) }) {
                await synchronizePairings()
                routePendingTap()
            }
        }
        Task {
            for await _ in Observations({ (ChatController.shared.badge, ChatController.shared.conversations, Pairings.shared.active?.host, Pairings.shared.state) }) {
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

    /// Asked once per launch, and only once a paired host sends pushes: a refusal cannot be asked again.
    static func requestPermission() async {
        guard !permissionRequested, Pairings.shared.entries.contains(where: { $0.features.contains("push") }) else { return }
        permissionRequested = true
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .badge, .sound]) }
            catch { CallLog.log(.net, "push permission_failed \(CallLog.describe(error))") }
        }
        UIApplication.shared.registerForRemoteNotifications()
    }

    static func environment(_ value: String?) -> String? {
        switch value { case "development": "sandbox"; case "production": "production"; default: nil }
    }

    static func tokenString(_ deviceToken: Data) -> String { deviceToken.map { String(format: "%02x", $0) }.joined() }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        token = Self.tokenString(deviceToken)
        Task { await synchronizePairings() }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        CallLog.log(.net, "push registration_failed \(CallLog.describe(error))")
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
        guard let environment = Self.environment(Bundle.main.object(forInfoDictionaryKey: Self.apsEnvironmentKey) as? String) else {
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
            } catch { CallLog.log(.net, "push upload_failed \(AppError.map(error).logName)") }
        }
    }

    static func presentation(for data: PushData?, host: URL?, conversationID: String?) -> UNNotificationPresentationOptions {
        if let data, let host, PairedHost.key(data.h) == PairedHost.key(host), data.c == conversationID { return [] }
        return [.banner, .list, .sound, .badge]
    }

    /// The pairing a push names: hosts compare by key, so a trailing slash or case in the server's base still matches.
    static func entry(for data: PushData, in entries: [Pairings.Entry]) -> Pairings.Entry? {
        guard let key = PairedHost.key(data.h) else { return nil }
        return entries.first { PairedHost.key($0.host) == key }
    }

    /// Delivered notifications clear only when the read order rises: the first sight of a conversation (every launch,
    /// every host switch) only records it, so opening the app leaves unread notifications in place.
    static func clearsDelivered(previous: Int64?, readOrder: Int64) -> Bool {
        guard let previous else { return false }
        return readOrder > previous
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let data = MessageNotification.payload(from: notification.request.content.userInfo)?.hd
        return await Self.presentation(for: data, host: Pairings.shared.active?.host, conversationID: ChatController.shared.openConversationId)
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
        guard let entry = Self.entry(for: data, in: Pairings.shared.entries) else {
            CallLog.log(.net, "push unknown_host")
            ChatController.shared.closeConversation()
            return
        }
        do {
            if Pairings.shared.active?.host != entry.host { try Pairings.shared.setActive(host: entry.host) }
            ChatController.shared.openConversation(data.c)
        } catch { CallLog.log(.net, "push routing_failed \(AppError.map(error).logName)") }
    }

    private func synchronizeReadState() async {
        let center = UNUserNotificationCenter.current()
        guard let active = Pairings.shared.active else {
            // Readable and unpaired: no screen is left that could clear what the last pairing delivered.
            guard Pairings.shared.state == .none, lastBadge != "" else { return }
            do { try await center.setBadgeCount(0) } catch { CallLog.log(.net, "push badge_failed \(CallLog.describe(error))") }
            center.removeAllDeliveredNotifications()
            lastBadge = ""
            reads = [:]
            return
        }
        let host = PairedHost.key(active.host)
        let identity = host + ":" + active.deviceId
        let chat = ChatController.shared
        if let badge = chat.badge {
            let value = "\(identity):\(badge.rev):\(badge.unreadTotal)"
            if lastBadge != value {
                do { try await center.setBadgeCount(badge.unreadTotal); lastBadge = value }
                catch { CallLog.log(.net, "push badge_failed \(CallLog.describe(error))") }
            }
        }
        var cleared: Set<String> = []
        for conversation in chat.conversations {
            let key = identity + ":" + conversation.id
            let previous = reads[key]
            reads[key] = max(previous ?? conversation.readOrder, conversation.readOrder)
            if Self.clearsDelivered(previous: previous, readOrder: conversation.readOrder) { cleared.insert(conversation.id) }
        }
        guard !cleared.isEmpty else { return }
        let ids = await center.deliveredNotifications().filter {
            cleared.contains($0.request.content.threadIdentifier)
                && MessageNotification.payload(from: $0.request.content.userInfo).flatMap { PairedHost.key($0.hd.h) } == host
        }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    #if DEBUG
    private func debugNotification() async {
        guard let id = ProcessInfo.processInfo.environment["HEYDAN_DEBUG_NOTIFY"] else { return }
        try? await Task.sleep(for: .seconds(8))
        guard let entry = Pairings.shared.active, let agent = entry.agents.first else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        CallLog.log(.net, "push directMessagesSetting=\(settings.directMessagesSetting.rawValue) environment=\(Bundle.main.object(forInfoDictionaryKey: Self.apsEnvironmentKey) as? String ?? "missing")")
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
            try await center.add(UNNotificationRequest(identifier: "debug-notification", content: content, trigger: nil))
        } catch { CallLog.log(.net, "push debug_failed \(CallLog.describe(error))") }
    }
    #endif
}
