import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var delivery: Delivery?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let next = Delivery(original: request.content, handler: contentHandler)
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

    // The lock claims the handler once, including when expiry races the donation callback.
    private final class Delivery: @unchecked Sendable {
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
}
