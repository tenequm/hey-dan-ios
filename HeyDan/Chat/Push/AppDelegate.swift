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
    private var routingTap: Task<Void, Never>?
    private var pendingTap: PushData?
    var clientFor: (Pairings.Entry) -> any AppService = { SignedClient(host: $0.host, deviceId: $0.deviceId, requestTimeout: 4) }
    var deliveredMessages: () async -> [(String, PushData)] = {
        await UNUserNotificationCenter.current().deliveredNotifications().compactMap { notification in
            MessageNotification.payload(from: notification.request.content.userInfo).map { (notification.request.identifier, $0.hd) }
        }
    }
    var removeDelivered: ([String]) -> Void = { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) }
    var postFailure: (UNNotificationRequest) async throws -> Void = { try await UNUserNotificationCenter.current().add($0) }
    private var reads: [String: Int64] = [:]
    private var lastBadge: Badge?
    private var lastPairing: String?
    private var lastHosts: [String: String]?
    private var pendingClears: Set<String> = []
    private var registered = false
    private var invalidEnvironmentLogged = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        guard IdentityKeychain.callTestRun == nil else { return true }
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
        guard IdentityKeychain.callTestRun == nil, !permissionRequested, Pairings.shared.entries.contains(where: { $0.features.contains("push") }) else { return }
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
        guard IdentityKeychain.callTestRun == nil else { return }
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
        let info = response.notification.request.content.userInfo
        let data = MessageNotification.payload(from: info)?.hd ?? (info["replyFailure"] as? Data).flatMap { try? JSONDecoder().decode(PushData.self, from: $0) }
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            if action == UNNotificationDefaultActionIdentifier {
                receiveTap(data)
                completionHandler()
                return
            }
            NotificationActionTask().run {
                await self.handleResponse(action: action, text: text, data: data)
            } completion: { completionHandler() }
        }
    }

    func handleResponse(action: String, text: String?, data: PushData?, pairings: Pairings = .shared,
                        files: OutboxFile = .shared, chat: @autoclosure () -> ChatController = ChatController.shared) async {
        guard let data else { return }
        let entry = Self.entry(for: data, in: pairings.notificationEntries())
        switch action {
        case Self.replyAction:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let entry, text.utf8.count <= Outbox.maximumTextBytes else { await replyFailed(data); return }
            let reply = Outbox.Entry(host: entry.host, conversationId: data.c,
                request: SendRequest(clientId: UUID().uuidString, text: text, fileIds: []))
            do { try await files.update(from: [], to: [reply], host: entry.host, deviceId: entry.deviceId) }
            catch { await replyFailed(data); return }
            guard Self.entry(for: data, in: pairings.notificationEntries())?.deviceId == entry.deviceId else {
                try? await files.update(from: [reply], to: [], host: entry.host, deviceId: entry.deviceId)
                await replyFailed(data)
                return
            }
            do {
                try Task.checkCancellation()
                _ = try await clientFor(entry).send(conversationId: data.c, request: reply.request)
                try await files.update(from: [reply], to: [], host: entry.host, deviceId: entry.deviceId)
            } catch {
                await files.deferReply(reply, deviceId: entry.deviceId)
                CallLog.log(.store, "push reply_deferred")
            }
        case Self.readAction:
            guard let entry else { return }
            let client = clientFor(entry)
            for attempt in 0...1 {
                do {
                    try Task.checkCancellation()
                    try await markRead(data, entry: entry, pairings: pairings, chat: chat(), client: client)
                    return
                } catch {
                    if Task.isCancelled { return }
                    if attempt == 1 { CallLog.log(.net, "push read_failed \(AppError.map(error).logName)") }
                }
            }
        default: break
        }
    }

    private func replyFailed(_ data: PushData) async {
        let content = UNMutableNotificationContent()
        content.title = "Reply not sent"
        content.threadIdentifier = data.c
        content.userInfo["replyFailure"] = try? JSONEncoder().encode(data)
        do { try await postFailure(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
        catch { CallLog.log(.store, "push reply_notice_failed") }
    }

    private func markRead(_ data: PushData, entry: Pairings.Entry, pairings: Pairings, chat: ChatController,
                          client: any AppService) async throws {
        let samePairing = { chat.host == entry.host && chat.pairing?.deviceId == entry.deviceId }
        var orders: [String: Int64] = [:]
        func remember(_ entities: some Sequence<ThreadEntity>) {
            for entity in entities {
                if let item = entity.identity, item.conversationId == data.c { orders[item.id] = item.order }
            }
        }
        func lookUpCachedOrders(_ ids: [String]) async {
            if samePairing() { remember(ids.compactMap { chat.reducer.entities[$0] }) }
            let missing = ids.filter { orders[$0] == nil }
            if !missing.isEmpty, let cached = try? await chat.store.itemOrders(missing, conversationId: data.c, host: entry.host, deviceId: entry.deviceId) {
                orders.merge(cached) { known, _ in known }
            }
        }
        await lookUpCachedOrders([data.m])
        var before: Int64?
        var more = true
        func fetchPage() async throws {
            try Task.checkCancellation()
            let page = try await client.history(conversationId: data.c, query: HistoryQuery(before: before, limit: 100))
            remember(page.items)
            let oldest = page.items.compactMap(\.order).min()
            more = page.hasMoreBefore && oldest.map { $0 < (before ?? .max) } == true
            before = oldest
        }
        while orders[data.m] == nil && more { try await fetchPage() }
        guard let order = orders[data.m] else { return }
        try Task.checkCancellation()
        let read = try await client.markRead(conversationId: data.c, request: ReadRequest(order: order))
        let delivered = await deliveredMessages().filter { _, item in
            item.c == data.c && PairedHost.key(item.h) == PairedHost.key(entry.host)
        }
        await lookUpCachedOrders(delivered.map { $0.1.m })
        do {
            while more && delivered.contains(where: { orders[$0.1.m] == nil }) { try await fetchPage() }
        } catch { CallLog.log(.net, "push delivered_lookup_failed") }
        try Task.checkCancellation()
        guard Self.entry(for: data, in: pairings.notificationEntries())?.deviceId == entry.deviceId else { return }
        removeDelivered(delivered.compactMap { id, item in orders[item.m].map { $0 <= order } == true ? id : nil })
        if samePairing() {
            chat.reducer.upsert(read.badge)
            try await chat.persist(chat.reducer.upsert(read.conversation))
        }
        if let total = try HostBadges.shared?.update(host: PairedHost.key(entry.host), count: read.badge.unreadTotal) {
            try await UNUserNotificationCenter.current().setBadgeCount(total)
        }
    }

    private func receiveTap(_ data: PushData?) {
        routingTap?.cancel()
        pendingTap = data
        if data == nil, !CallController.shared.openActiveConversation() { ChatController.shared.showNotificationList() }
        routePendingTap()
    }
    private func routePendingTap() {
        guard Pairings.shared.state != .unreadable, let data = pendingTap else { return }
        pendingTap = nil
        if CallController.shared.openActiveConversation() { return }
        guard let entry = Self.entry(for: data, in: Pairings.shared.entries) else {
            CallLog.log(.net, "push unknown_host")
            ChatController.shared.showNotificationList()
            return
        }
        do {
            if Pairings.shared.active?.host != entry.host { try Pairings.shared.setActive(host: entry.host) }
            routingTap = Task { await ChatController.shared.routeNotification(to: data.c) }
        } catch { CallLog.log(.net, "push routing_failed \(AppError.map(error).logName)") }
    }

    static func clearHidden(host: URL, conversations: Set<String> = [], agentID: String? = nil) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications().compactMap { notification -> String? in
            guard let data = MessageNotification.payload(from: notification.request.content.userInfo)?.hd,
                  matchesHidden(data, host: host, conversations: conversations, agentID: agentID) else { return nil }
            return notification.request.identifier
        }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func matchesHidden(_ data: PushData, host: URL, conversations: Set<String>, agentID: String?) -> Bool {
        PairedHost.key(data.h) == PairedHost.key(host) && (conversations.contains(data.c) || data.a.id == agentID)
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
        for conversation in chat.reducer.conversations.values {
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

@MainActor
final class NotificationActionTask {
    private var background = UIBackgroundTaskIdentifier.invalid
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var completion: (() -> Void)?

    func run(timeout: Duration = .seconds(18), operation: @escaping @MainActor () async -> Void,
             completion: @escaping () -> Void) {
        self.completion = completion
        background = UIApplication.shared.beginBackgroundTask(withName: "Message notification") { self.finish() }
        work = Task { await operation(); finish() }
        timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            finish()
        }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        work?.cancel()
        timer?.cancel()
        if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        completion()
    }
}
