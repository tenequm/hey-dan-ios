import ActivityKit
import Foundation
import Observation

/// The call's Live Activity: requested when a call starts, updated only when what it shows changes, ended with the
/// call. Local updates only; its clocks are timer texts, so a running call sends nothing per second.
@MainActor
final class CallActivity {
    typealias State = CallActivityAttributes.ContentState

    /// The running activity, by id: an `Activity` is not Sendable, so each update finds it again off the main actor.
    private var activityID: String?
    private var shown: State?

    /// How long the ended call stays on the lock screen.
    private static let endedLinger: TimeInterval = 5

    static func follow(_ call: CallController) {
        let activity = CallActivity()
        Task { await activity.run(call) }
    }

    private func run(_ call: CallController) async {
        // One left by an earlier run of the app (killed mid-call) belongs to no call.
        for stale in Activity<CallActivityAttributes>.activities {
            await stale.end(nil, dismissalPolicy: .immediate)
            CallLog.log(.activity, "end stale id=\(stale.id.prefix(8))")
        }
        #if DEBUG && targetEnvironment(simulator)
            if showSample() { return }
        #endif
        // Changes made together (a call ending unmutes, then ends) arrive as one.
        for await (phase, muted, agentName, liveSince, thinkingSince) in Observations({
            (call.phase, call.isMuted, call.agentName, call.liveSince, call.thinkingSince)
        }) {
            await show(phase, muted: muted, agentName: agentName, liveSince: liveSince, thinkingSince: thinkingSince)
        }
    }

    private func show(
        _ phase: CallController.Phase, muted: Bool, agentName: String, liveSince: Date?, thinkingSince: Date?
    ) async {
        let stage: State.Stage
        switch phase {
        case .idle:
            return await end(stage: .ended, muted: false, agentName: agentName, liveSince: liveSince, dismissal: .immediate)
        case .connecting:
            stage = .connecting
        case let .live(activity):
            stage = switch activity {
            case .listening: .listening
            case .thinking: .thinking
            case .speaking: .speaking
            }
        case .reconnecting:
            stage = .reconnecting
        case let .ended(ending):
            let failed = CallController.isFailure(ending, liveSince: liveSince)
            return await end(
                stage: failed ? .failed : .ended, muted: muted, agentName: agentName, liveSince: liveSince,
                dismissal: .after(.now + Self.endedLinger)
            )
        }
        let state = State(
            stage: stage, muted: muted, agentName: agentName, liveSince: liveSince, thinkingSince: thinkingSince
        )
        guard state != shown else { return }
        shown = state
        if let activityID {
            // Gone when the caller swiped it away: the call carries on without it.
            guard let activity = Self.activity(activityID) else {
                return CallLog.log(.activity, "update skipped id=\(activityID.prefix(8)) gone", level: .info)
            }
            let asked = ContinuousClock.now
            await activity.update(ActivityContent(state: state, staleDate: nil))
            CallLog.log(
                .activity,
                "update id=\(activityID.prefix(8)) stage=\(state.stage.rawValue) muted=\(state.muted) ms=\(CallLog.ms(since: asked))",
                level: .info
            )
        } else {
            start(state)
        }
    }

    private func end(
        stage: State.Stage, muted: Bool, agentName: String, liveSince: Date?, dismissal: ActivityUIDismissalPolicy
    ) async {
        let final = State(stage: stage, muted: muted, agentName: agentName, liveSince: liveSince, endedAt: .now)
        shown = nil
        guard let activityID else { return }
        self.activityID = nil
        guard let activity = Self.activity(activityID) else {
            return CallLog.log(.activity, "end skipped id=\(activityID.prefix(8)) gone")
        }
        let asked = ContinuousClock.now
        await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: dismissal)
        CallLog.log(.activity, "end id=\(activityID.prefix(8)) stage=\(stage.rawValue) ms=\(CallLog.ms(since: asked))")
    }

    nonisolated private static func activity(_ id: String) -> Activity<CallActivityAttributes>? {
        Activity<CallActivityAttributes>.activities.first { $0.id == id }
    }

    private func start(_ state: State) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return CallLog.log(.activity, "request skipped: live activities are off for this app")
        }
        do {
            let id = try Activity.request(
                attributes: CallActivityAttributes(), content: ActivityContent(state: state, staleDate: nil)
            ).id
            activityID = id
            CallLog.log(.activity, "request ok id=\(id.prefix(8)) stage=\(state.stage.rawValue)")
        } catch {
            CallLog.log(.activity, "request failed \(CallLog.describe(error))", level: .error)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
        /// A stand-in call's activity for screenshots, from `HEYDAN_PREVIEW_ACTIVITY`: a stage name, or `muted`.
        private func showSample() -> Bool {
            guard let name = ProcessInfo.processInfo.environment["HEYDAN_PREVIEW_ACTIVITY"],
                  let stage = State.Stage(rawValue: name == "muted" ? "listening" : name) else { return false }
            let liveSince = stage == .connecting || stage == .failed ? nil : Date(timeIntervalSinceNow: -83)
            let state = State(
                stage: stage, muted: name == "muted", agentName: "Dan", liveSince: liveSince,
                thinkingSince: stage == .thinking ? Date(timeIntervalSinceNow: -12) : nil,
                endedAt: stage == .ended || stage == .failed ? .now : nil
            )
            start(state)
            // An alert a moment later shows the expanded island (or the banner, without one) once the app is away.
            if let activityID {
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await Self.activity(activityID)?.update(
                        ActivityContent(state: state, staleDate: nil),
                        alertConfiguration: AlertConfiguration(title: "hey dan", body: "sample call", sound: .default)
                    )
                }
            }
            return true
        }
    #endif
}
