import HeyDanCore
import Intents
import OSLog
import UIKit
import UserNotifications

// The notification extension and app both replace a host's count. Coordinate the whole read-modify-write.
nonisolated struct HostBadges {
    struct Entry: Codable, Equatable {
        var device: String
        var count = 0
    }

    let file: URL
    static var shared: Self? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HeyDanBadgeGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return Self(file: root.appending(path: "badge-counts.json"))
    }

    func update(pairings: [String: String]? = nil, host: String? = nil, count: Int? = nil) throws -> Int {
        var coordinationError: NSError?
        var result: Result<Int, any Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) { url in
            result = Result {
                let previous: [String: Entry]
                do { previous = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url)) }
                catch CocoaError.fileReadNoSuchFile { previous = [:] }
                var entries = previous
                if let pairings {
                    entries = pairings.mapValues { Entry(device: $0) }
                    for (key, entry) in previous where pairings[key] == entry.device { entries[key] = entry }
                }
                if let host, let count { entries[host]?.count = max(0, count) }
                if entries != previous {
                    try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                return entries.values.reduce(0) { sum, entry in sum + min(Int.max - sum, entry.count) }
            }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    static func incoming(_ original: UNNotificationContent) -> UNNotificationContent {
        guard let payload = MessageNotification.payload(from: original.userInfo),
              let host = PairedHost.key(payload.hd.h), let store = shared,
              let total = try? store.update(host: host, count: payload.aps.badge),
              let content = original.mutableCopy() as? UNMutableNotificationContent else { return original }
        content.badge = NSNumber(value: total)
        return content
    }
}

@MainActor enum MessageNotification {
    // The extension logs under the app's subsystem, so `just logs` shows both.
    private static let logger = Logger(subsystem: (Bundle.main.bundleIdentifier ?? "HeyDan")
        .replacing(/\.NotificationService$/, with: ""), category: "notification")

    nonisolated static func payload(from userInfo: [AnyHashable: Any]) -> PushPayload? {
        // A non-JSON value (a local notification's Date) would raise an Objective-C exception, not a Swift error.
        guard JSONSerialization.isValidJSONObject(userInfo), let data = try? JSONSerialization.data(withJSONObject: userInfo),
              let payload = try? JSONDecoder().decode(PushPayload.self, from: data),
              payload.hd.v == 1, !payload.hd.h.isEmpty else { return nil }
        return payload
    }

    static func intent(for payload: PushPayload) -> INSendMessageIntent {
        INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: payload.aps.alert.body,
            speakableGroupName: nil,
            conversationIdentifier: payload.hd.c,
            serviceName: nil,
            sender: person(for: payload.hd.a),
            attachments: nil
        )
    }

    static func content(for payload: PushPayload, original: UNNotificationContent) async -> UNNotificationContent {
        let intent = intent(for: payload)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            return try original.updating(from: intent)
        } catch {
            logger.error("communication_update_failed \(describe(error), privacy: .public)")
            return original
        }
    }

    static func content(for original: UNNotificationContent) async -> UNNotificationContent {
        guard let payload = payload(from: original.userInfo) else {
            logger.error("invalid_push_payload")
            return original
        }
        return await content(for: payload, original: original)
    }

    static func donateOutgoing(agent: Agent, conversationID: String) async {
        let intent = INSendMessageIntent(
            recipients: [person(for: agent)],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            conversationIdentifier: conversationID,
            serviceName: nil,
            sender: nil,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        do { try await interaction.donate() }
        catch { logger.error("outgoing_donation_failed \(describe(error), privacy: .public)") }
    }

    private static func describe(_ error: any Error) -> String {
        "\((error as NSError).domain)(\((error as NSError).code))"
    }

    private static var avatars: [String: Data] = [:]

    private static func person(for agent: Agent) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: agent.id, type: .unknown),
            nameComponents: nil,
            displayName: agent.name,
            image: avatar(for: agent).map { INImage(imageData: $0) },
            contactIdentifier: nil,
            customIdentifier: agent.id
        )
    }

    private static func avatar(for agent: Agent) -> Data? {
        let cacheKey = agent.id + "|" + agent.name
        if let cached = avatars[cacheKey] { return cached }
        let theme = Theme.dark
        let size = CGSize(width: theme.space.s10, height: theme.space.s10)
        let avatar = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(theme.color.prominent).setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            let initial = agent.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1).uppercased()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: theme.type.headline.size, weight: .bold),
                .foregroundColor: UIColor(theme.color.onProminent),
            ]
            let text = (initial.isEmpty ? "?" : initial) as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                 y: (size.height - bounds.height) / 2), withAttributes: attributes)
        }
        let data = avatar.pngData()
        avatars[cacheKey] = data
        return data
    }
}

// The lock claims the handler once, including when expiry races the donation callback.
final class NotificationDelivery: @unchecked Sendable {
    let original: UNNotificationContent
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?

    init(original: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.original = original
        self.handler = handler
    }

    func finish(_ content: UNNotificationContent? = nil) {
        let callback = lock.withLock {
            let callback = handler
            handler = nil
            return callback
        }
        callback?(content ?? original)
    }
}
