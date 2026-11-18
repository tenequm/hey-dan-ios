import HeyDanCore
import Intents
import OSLog
import UIKit
import UserNotifications

enum MessageNotification {
    // The extension logs under the app's subsystem, so `just logs` shows both.
    private static let logger = Logger(subsystem: (Bundle.main.bundleIdentifier ?? "HeyDan")
        .replacing(/\.NotificationService$/, with: ""), category: "notification")

    static func payload(from userInfo: [AnyHashable: Any]) -> PushPayload? {
        guard let data = try? JSONSerialization.data(withJSONObject: userInfo),
              let payload = try? JSONDecoder().decode(PushPayload.self, from: data),
              payload.hd.v == 1, !payload.hd.h.isEmpty else { return nil }
        return payload
    }

    @MainActor
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

    @MainActor
    static func content(for payload: PushPayload, original: UNNotificationContent) async -> UNNotificationContent {
        let intent = intent(for: payload)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            return try original.updating(from: intent)
        } catch {
            logger.error("communication_update_failed")
            return original
        }
    }

    @MainActor
    static func content(for original: UNNotificationContent) async -> UNNotificationContent {
        guard let payload = payload(from: original.userInfo) else {
            logger.error("invalid_push_payload")
            return original
        }
        return await content(for: payload, original: original)
    }

    @MainActor
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
        catch { logger.error("outgoing_donation_failed") }
    }

    @MainActor
    private static func person(for agent: Agent) -> INPerson {
        let size = CGSize(width: 96, height: 96)
        let avatar = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemIndigo.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            let initials = agent.name.split(whereSeparator: \.isWhitespace).prefix(2)
                .compactMap(\.first).map(String.init).joined().uppercased()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = (initials.isEmpty ? "?" : initials) as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                 y: (size.height - bounds.height) / 2), withAttributes: attributes)
        }
        return INPerson(
            personHandle: INPersonHandle(value: agent.id, type: .unknown),
            nameComponents: nil,
            displayName: agent.name,
            image: avatar.pngData().map { INImage(imageData: $0) },
            contactIdentifier: nil,
            customIdentifier: agent.id
        )
    }
}
