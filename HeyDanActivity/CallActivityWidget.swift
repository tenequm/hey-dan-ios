import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HeyDanActivityBundle: WidgetBundle {
    var body: some Widget {
        CallActivityWidget()
    }
}

struct CallActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            LockScreenCall(state: context.state)
                .activityBackgroundTint(Theme.card)
                .activitySystemActionForegroundColor(Theme.text)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        StageGlyph(state: state).font(.system(size: 15, weight: .semibold))
                        Text(state.agentName.lowercased())
                            .font(Theme.mono(16, medium: true))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CallClock(state: state)
                        .font(Theme.mono(16))
                        .foregroundStyle(Theme.text)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        StatusChip(state: state)
                        Spacer(minLength: 0)
                        if state.isOpen { EndKey() }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
            } compactLeading: {
                StageGlyph(state: state).font(.system(size: 13, weight: .semibold))
            } compactTrailing: {
                CompactClock(state: state)
            } minimal: {
                StageGlyph(state: state).font(.system(size: 13, weight: .semibold))
            }
            .keylineTint(state.ink)
        }
    }
}

/// The lock screen banner, in the call screen's dark style.
private struct LockScreenCall: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.isLive ? Theme.ok : Theme.ledOff)
                    .frame(width: 8, height: 8)
                Text("hey \(state.agentName.lowercased())")
                    .font(Theme.mono(15, medium: true))
                    .foregroundStyle(Theme.text)
                if state.muted, state.isOpen {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel("mic muted")
                }
                Spacer(minLength: 8)
                CallClock(state: state)
                    .font(Theme.mono(15))
                    .foregroundStyle(state.isOpen ? Theme.text : Theme.muted)
            }
            HStack(spacing: 8) {
                StatusChip(state: state)
                Spacer(minLength: 0)
                if state.isOpen { EndKey() }
            }
        }
        .padding(16)
    }
}

/// The call screen's readout chip, with how long the agent has been working.
private struct StatusChip: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        let style = state.chip
        HStack(spacing: 7) {
            if let dot = style.dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(state.status)
            if state.stage == .thinking, let since = state.thinkingSince {
                Text("·")
                Text(timerInterval: since ... Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .leading)
            }
        }
        .font(Theme.mono(14, medium: true))
        .foregroundStyle(style.ink)
        .lineLimit(1)
        .padding(EdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 4).fill(style.fill))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style.outline, lineWidth: 1))
    }
}

/// How long the call has run: counting while it is on, fixed once it ended, absent before it went live.
private struct CallClock: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        if let since = state.liveSince {
            Group {
                if let end = state.endedAt {
                    Text(Duration.seconds(end.timeIntervalSince(since)).formatted(.time(pattern: .minuteSecond)))
                } else {
                    Text(timerInterval: since ... Date.distantFuture, countsDown: false)
                }
            }
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            // A timer text takes all the width it is offered: room for an hour-long call.
            .frame(width: 72, alignment: .trailing)
        }
    }
}

/// The Dynamic Island's compact clock: the agent's working time while it works, else the call's.
private struct CompactClock: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        let working = state.stage == .thinking ? state.thinkingSince : nil
        if let since = working ?? state.liveSince, state.isOpen {
            Text(timerInterval: since ... Date.distantFuture, countsDown: false)
                .font(Theme.mono(13, medium: true))
                .monospacedDigit()
                .foregroundStyle(working == nil ? Theme.text : Theme.think)
                .multilineTextAlignment(.trailing)
                // Four digits: an hour of call.
                .frame(width: 40, alignment: .trailing)
        }
    }
}

private struct StageGlyph: View {
    let state: CallActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.symbol)
            .foregroundStyle(state.ink)
            .accessibilityLabel(state.status)
    }
}

private struct EndKey: View {
    var body: some View {
        Button(intent: EndCallIntent()) {
            Label("end", systemImage: "phone.down.fill")
                .font(Theme.mono(14, medium: true))
                .foregroundStyle(Theme.onOrange)
                .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 14))
                .background(Capsule().fill(Theme.orange))
        }
        .buttonStyle(.plain)
    }
}

private extension CallActivityAttributes.ContentState {
    var isOpen: Bool { stage != .ended && stage != .failed }

    var isLive: Bool { [.listening, .thinking, .speaking].contains(stage) }

    private var mutedListening: Bool { stage == .listening && muted }

    /// The call screen's chip words.
    var status: String {
        if mutedListening { return "mic muted" }
        let name = agentName.lowercased()
        return switch stage {
        case .connecting: "connecting…"
        case .listening: "listening"
        case .thinking: "\(name) is working"
        case .speaking: "\(name) is speaking"
        case .reconnecting: "reconnecting…"
        case .ended: "call ended"
        case .failed: "could not call"
        }
    }

    var ink: Color {
        if mutedListening { return Theme.screenSoft }
        return switch stage {
        case .listening, .speaking: Theme.orange
        case .thinking: Theme.think
        case .failed: Theme.error
        case .connecting, .reconnecting, .ended: Theme.screenSoft
        }
    }

    var symbol: String {
        if mutedListening { return "mic.slash.fill" }
        return switch stage {
        case .connecting: "phone.arrow.up.right.fill"
        case .listening: "mic.fill"
        case .thinking: "ellipsis"
        case .speaking: "waveform"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .ended, .failed: "phone.down.fill"
        }
    }

    var chip: ChipPalette {
        if mutedListening { return .quiet }
        return switch stage {
        case .listening: .you
        case .speaking: .speaking
        case .thinking: .thinking
        case .failed: .error
        case .connecting, .reconnecting, .ended: .quiet
        }
    }
}
