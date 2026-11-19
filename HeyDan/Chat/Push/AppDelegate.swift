import HeyDanCore
import Observation
import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let apsEnvironmentKey = "HeyDanAPSEnvironment"
    static let replyAction = "message.reply"
    static let readAction = "message.read"
    static var messageCategory: UNNotificationCategory {
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: [.authenticationRequired],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let read = UNNotificationAction(identifier: readAction, title: "Mark as Read")
        return UNNotificationCategory(identifier: "message", actions: [reply, read], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "New message", options: [])
    }

    private static var permissionRequested = false
    private var synchronizing = false
    private var synchronizeAgain = false
    private var token: String?
    private var uploaded: [String: String] = [:]
    private var pendingTap: PushData?
    private var pendingReply: Task<Void, Never>?
    private var reads: [String: Int64] = [:]
    private var lastBadge: Badge?
    private var lastPairing: String?
    private var lastHosts: [String: String]?
    private var pendingClears: Set<String> = []
    private var registered = false
    private var invalidEnvironmentLogged = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.messageCategory])
        Task {
            // A reconnect retries an upload that failed while the app stayed open.
            for await _ in Observations({ (Pairings.shared.entries, Pairings.shared.state, ChatController.shared.connectionState == .connected) }) {
                await synchronizePairings()
                routePendingTap()
            }
        }
        Task {
            for await _ in Observations({ (ChatController.shared.badge, ChatController.shared.conversations, Pairings.shared.entries, Pairings.shared.active?.host, Pairings.shared.state) }) {
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
        if ProcessInfo.processInfo.environment["HEYDAN_CHAT_CHECKS"] == "1" {
            Task {
                while !Task.isCancelled {
                    let count = await center.deliveredNotifications().count
                    CallLog.log(.net, "check push delivered=\(count) badge=\(UIApplication.shared.applicationIconBadgeNumber)")
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
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
        #if DEBUG
        if Pairings.shared.isFixture { return }
        #endif
        for entry in entries where entry.host != Pairings.shared.active?.host {
            let client = SignedClient(host: entry.host, deviceId: entry.deviceId)
            guard let badge = try? await client.conversations().badge,
                  Pairings.shared.active?.host != entry.host,
                  Pairings.shared.entries.contains(where: { $0.host == entry.host && $0.deviceId == entry.deviceId }) else { continue }
            let roster = Self.badgeHosts()
            if let total = try? HostBadges.shared?.update(pairings: roster, host: PairedHost.key(entry.host), count: badge.unreadTotal) {
                try? await UNUserNotificationCenter.current().setBadgeCount(total)
            }
        }
        guard let token else { return }
        guard let environment = Self.environment(Bundle.main.object(forInfoDictionaryKey: Self.apsEnvironmentKey) as? String) else {
            if !invalidEnvironmentLogged { CallLog.log(.net, "push invalid_environment"); invalidEnvironmentLogged = true }
            return
        }
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
        let payload = MessageNotification.payload(from: notification.request.content.userInfo)
        var options = await Self.presentation(for: payload?.hd, host: Pairings.shared.active?.host, conversationID: ChatController.shared.openConversationId)
        if let payload, let host = PairedHost.key(payload.hd.h),
           let total = try? HostBadges.shared?.update(pairings: await Self.badgeHosts(), host: host, count: payload.aps.badge) {
            try? await center.setBadgeCount(total)
            options.remove(.badge)
        }
        return options
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let data = MessageNotification.payload(from: response.notification.request.content.userInfo)?.hd
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            await handleResponse(action: action, text: text, data: data)
            // UIKit updates state restoration from this completion on the main thread.
            completionHandler()
        }
    }
    func handleResponse(action: String, text: String?, data: PushData?, pairings: Pairings = .shared,
                        chat: ChatController = .shared) async {
        if action == UNNotificationDefaultActionIdentifier { receiveTap(data); return }
        pairings.loadIfNeeded()
        guard let data, let entry = Self.entry(for: data, in: pairings.entries) else { return }
        do {
            switch action {
            case Self.replyAction:
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let previous = pendingReply
                pendingReply = Task {
                    await previous?.value
                    guard pairings.entries.contains(where: { $0.host == entry.host && $0.deviceId == entry.deviceId }) else { return }
                    do {
                        // The selected host owns the durable outbox and resumes its sends on reconnect.
                        if pairings.active?.host != entry.host { try pairings.setActive(host: entry.host) }
                        chat.selectPairing(entry.pairing, host: entry.host)
                        if UIApplication.shared.applicationState == .background { chat.setActive(false) }
                        if !(await chat.enqueueReply(text, conversationId: data.c, entry: entry)) {
                            CallLog.log(.store, "push reply_not_queued")
                        }
                    } catch { CallLog.log(.net, "push reply_failed \(AppError.map(error).logName)") }
                }
                await pendingReply?.value
            case Self.readAction:
                try await markRead(data, entry: entry, pairings: pairings, chat: chat)
            default: break
            }
        } catch { CallLog.log(.net, "push action_failed \(AppError.map(error).logName)") }
    }

    private func markRead(_ data: PushData, entry: Pairings.Entry, pairings: Pairings, chat: ChatController) async throws {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().compactMap { notification -> String? in
            guard let item = MessageNotification.payload(from: notification.request.content.userInfo)?.hd,
                  item.c == data.c, PairedHost.key(item.h) == PairedHost.key(entry.host) else { return nil }
            return notification.request.identifier
        }
        let samePairing = { chat.host == entry.host && chat.pairing?.deviceId == entry.deviceId }
        let client: any AppService = samePairing() ? chat.service : SignedClient(host: entry.host, deviceId: entry.deviceId)
        // Protocol 1 pushes carry an item id but no order. A newest-page read covers the delivered snapshot.
        let page = try await client.history(conversationId: data.c, query: HistoryQuery(limit: 1))
        guard let order = page.items.compactMap(\.order).max() else { return }
        let read = try await client.markRead(conversationId: data.c, request: ReadRequest(order: order))
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        guard pairings.entries.contains(where: { $0.host == entry.host && $0.deviceId == entry.deviceId }) else { return }
        if samePairing() {
            chat.reducer.upsert(read.badge)
            try await chat.persist(chat.reducer.upsert(read.conversation))
        }
        if let total = try HostBadges.shared?.update(host: PairedHost.key(entry.host), count: read.badge.unreadTotal) {
            try await center.setBadgeCount(total)
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

    private static func badgeHosts() -> [String: String] {
        Dictionary(Pairings.shared.entries.map { (PairedHost.key($0.host), $0.deviceId) }, uniquingKeysWith: { first, _ in first })
    }

    private func synchronizeReadState() async {
        let center = UNUserNotificationCenter.current()
        let pairings = Pairings.shared
        guard pairings.state != .unreadable else { return }
        let hosts = Self.badgeHosts()
        let active = pairings.active
        let chat = ChatController.shared
        let host = active.map { PairedHost.key($0.host) }
        let identity = active.map { PairedHost.key($0.host) + ":" + $0.deviceId }
        let badge = chat.host == active?.host && chat.pairing?.deviceId == active?.deviceId ? chat.badge : nil
        if hosts != lastHosts || identity != lastPairing || badge != lastBadge {
            do {
                let total = try HostBadges.shared?.update(pairings: hosts, host: host, count: badge?.unreadTotal)
                try await center.setBadgeCount(total ?? badge?.unreadTotal ?? 0)
                lastBadge = badge
                lastPairing = identity
                lastHosts = hosts
            } catch { CallLog.log(.net, "push badge_failed \(CallLog.describe(error))") }
        }
        guard let host, let identity else {
            center.removeAllDeliveredNotifications()
            reads.removeAll()
            pendingClears.removeAll()
            return
        }
        guard chat.host == active?.host, chat.pairing?.deviceId == active?.deviceId else { return }
        var orders: [String: Int64] = [:]
        for conversation in chat.conversations {
            let key = identity + ":" + conversation.id
            let previous = reads.updateValue(conversation.readOrder, forKey: key)
            if Self.clearsDelivered(previous: previous, readOrder: conversation.readOrder) { pendingClears.insert(key) }
            if pendingClears.contains(key) { orders[conversation.id] = conversation.readOrder }
        }
        guard !orders.isEmpty else { return }
        let delivered = await center.deliveredNotifications()
        guard chat.host == active?.host, chat.pairing?.deviceId == active?.deviceId else { return }
        var unresolved: Set<String> = []
        let ids = delivered.compactMap { notification -> String? in
            guard let data = MessageNotification.payload(from: notification.request.content.userInfo)?.hd,
                  PairedHost.key(data.h) == host, let order = orders[data.c] else { return nil }
            if chat.reducer.entities[data.m] == nil { unresolved.insert(data.c) }
            return Self.isRead(data, through: order, entities: chat.reducer.entities) ? notification.request.identifier : nil
        }
        for id in orders.keys where !unresolved.contains(id) { pendingClears.remove(identity + ":" + id) }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func isRead(_ data: PushData, through readOrder: Int64, entities: [String: ThreadEntity]) -> Bool {
        guard let item = entities[data.m]?.identity, item.conversationId == data.c else { return false }
        return item.order <= readOrder
    }

    #if DEBUG
    private func debugNotification() async {
        guard let id = ProcessInfo.processInfo.environment["HEYDAN_DEBUG_NOTIFY"] else { return }
        try? await Task.sleep(for: .seconds(8))
        guard let entry = Pairings.shared.active, let agent = entry.agents.first else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        CallLog.log(.net, "push directMessagesSetting=\(settings.directMessagesSetting.rawValue) environment=\(Bundle.main.object(forInfoDictionaryKey: Self.apsEnvironmentKey) as? String ?? "missing")")
        let payload = PushPayload(aps: PushAPS(alert: PushAlert(title: agent.name, body: FixtureContent.capturing ? FixtureContent.notification : "New message"), threadId: id, mutableContent: 1, badge: 1, sound: "default", category: "message"), hd: PushData(h: entry.host.absoluteString, v: 1, c: id, m: "debug_message", k: .message, a: agent))
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
