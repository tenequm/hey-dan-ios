import ActivityKit
import AppIntents
import Foundation

/// A call on the lock screen and in the Dynamic Island; compiled into the app and the widget extension.
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Stage: String, Codable {
            case connecting, listening, thinking, speaking, reconnecting, ended, failed
        }

        var stage: Stage
        var muted = false
        var agentName: String
        /// When the call first went live: the call's clock counts from here.
        var liveSince: Date?
        /// When the agent started on the current turn.
        var thinkingSince: Date?
        var endedAt: Date?
    }
}

/// The end key on the activity. A `LiveActivityIntent` runs in the app's process, where the call is.
struct EndCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End call"
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !ACTIVITY_EXTENSION
            CallLog.log(.intent, "end call from the live activity")
            CallController.shared.hangUp()
        #endif
        return .result()
    }
}
