import HeyDanCore
import UserNotifications

/// H5 owns the shared communication-intent builder for the app and extension.
enum MessageNotification {
    static func content(for payload: PushPayload, original: UNNotificationContent) async -> UNNotificationContent { original }
}
