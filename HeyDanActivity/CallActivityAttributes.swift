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

struct CallDefaultAgentIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Call Default agent"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !ACTIVITY_EXTENSION
        let background = systemContext.currentMode == .background
        CallLog.log(.intent, "control start background=\(background)")
        do {
            try await IntentCall.run(agentID: nil, inBackground: background)
        } catch let error as IntentCall.CallNotStarted where error.message == IntentCall.backgroundRefused {
            guard systemContext.currentMode.canContinueInForeground else { throw error }
            CallLog.log(.intent, "control retry foreground")
            try await continueInForeground(alwaysConfirm: false)
            try await IntentCall.run(agentID: nil, inBackground: false)
        }
        #endif
        return .result()
    }
}
