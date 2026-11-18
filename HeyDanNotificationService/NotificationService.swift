import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var delivery: NotificationDelivery?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let next = NotificationDelivery(original: request.content, handler: contentHandler)
        let previous = lock.withLock {
            let previous = delivery
            delivery = next
            return previous
        }
        previous?.finish()
        Task { @MainActor in
            let content = await MessageNotification.content(for: next.original)
            next.finish(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        let pending = lock.withLock { delivery }
        pending?.finish()
    }
}
