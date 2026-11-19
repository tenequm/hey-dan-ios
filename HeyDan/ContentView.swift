import HeyDanCore
import SwiftUI

struct ContentView: View {
    @Environment(\.theme) private var theme
    let pairedTarget: CallTarget
    var minimize: (() -> Void)?
    @Environment(CallController.self) private var call
    @State private var presentsCallOptions = false
    @State private var optionsHeight: CGFloat = 240
    @State private var optionsVoice: VoiceSettingsModel?
    @State private var voiceTarget: VoiceTarget?
    @State private var pendingVoice: VoiceTarget?
    @State private var settingsBusy = false
    /// Right after "call" the same key reads "cancel": taps are ignored for a moment so a double tap cannot cancel.
    @State private var cancelArmed = false
    @State private var preview = Preview.fromEnvironment()

    private struct VoiceTarget: Identifiable {
        let id = UUID()
        let model: VoiceSettingsModel
        let agentName: String
        let callID: UUID?
    }

    var body: some View {
        VStack(spacing: theme.space.s4) {
            header
            screen
            controls
        }
        .padding(.horizontal, theme.space.s4)
        .padding(.bottom, theme.space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color.surface.ignoresSafeArea())
        .foregroundStyle(theme.color.textPrimary)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(isPresented: $presentsCallOptions, onDismiss: {
            voiceTarget = pendingVoice
            pendingVoice = nil
        }) { callOptions }
        .sheet(item: $voiceTarget) { target in
            VoicePickerSheet(model: target.model, agentName: target.agentName, callID: target.callID)
        }
        .task(id: isSettingUp) {
            cancelArmed = false
            guard isSettingUp else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { cancelArmed = true }
        }
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            VStack(spacing: 0) {
                Text(displayName).textRole(theme.type.headline, theme.weight.semibold)
                HStack(spacing: theme.space.s1) {
                    if let host = pairedTarget.paired.host.host() { Text(host) }
                    if let liveSince, isCallActive {
                        Text(liveSince, style: .timer).monospacedDigit().fixedSize()
                    } else { Text(callLabel) }
                }
                .lineLimit(1).textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
            }
            .padding(.horizontal, minimize == nil ? 0 : theme.control.touchTarget)
            if let minimize {
                GlassIconButton(title: "Close", systemImage: "chevron.down", action: minimize)
                    .accessibilityIdentifier("chat.call.close")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var displayName: String { pairedTarget.paired.conversation.agent.name }

    // MARK: Screen

    private var screen: some View {
        VStack(spacing: theme.space.s4) {
            Text(displayName.prefix(1).uppercased())
                .textRole(theme.type.display, theme.weight.bold)
                .foregroundStyle(theme.color.textPrimary)
                .frame(width: theme.control.touchTarget * 2, height: theme.control.touchTarget * 2)
                .background(theme.color.surfaceGrouped, in: Circle())
                .overlay { Circle().strokeBorder(theme.color.border) }
                .accessibilityHidden(true)
            chip
            if phase == .live(.speaking) {
                Image(systemName: "waveform")
                    .font(.system(size: theme.space.s6))
                    .foregroundStyle(theme.color.accent)
                    .accessibilityHidden(true)
            }
            hint
            TranscriptPane(
                standIn: preview?.transcript, agentName: displayName,
                start: liveSince,
                awake: onCall && commands?.wake == true && commands?.waiting == false,
                frozen: preview?.caret ?? false,
                empty: hintIsError ? nil : emptyDescription
            )
        }
        .padding(.horizontal, theme.space.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var emptyDescription: String {
        let agent = displayName
        if onCall {
            if isMuted { return "Unmute to speak." }
            return waitingWake ? "Say \"\(wakePhrase)\" to start." : "Speak when ready."
        }
        return switch phase {
        case .connecting, .reconnecting: "Connecting to \(agent)."
        case let .ended(ending) where !isFailure(ending): "Call again to keep talking."
        default: "Press call to talk to \(agent)."
        }
    }

    private var chip: some View {
        CallStateChip(label: chipText, dot: chipColor)
    }

    private var chipColor: Color {
        if hintIsError { return theme.color.danger }
        if phase == .connecting || phase == .reconnecting { return theme.color.warning }
        if isMuted { return theme.color.iconMuted }
        if phase == .live(.speaking) { return theme.color.accent }
        if isLive { return phase == .live(.thinking) ? theme.color.statusWorking : theme.color.statusConnected }
        return theme.color.iconMuted
    }

    @ViewBuilder private var hint: some View {
        Group {
            if case .live(.thinking) = phase, let thinkingSince {
                TimelineView(.periodic(from: thinkingSince, by: 1)) { context in
                    let waited = clock(context.date.timeIntervalSince(thinkingSince), pad: false)
                    Text("\(isMuted ? "unmute to keep talking" : "you can keep talking") · waiting \(waited)")
                }
            } else {
                Text(hintText)
            }
        }
        .textRole(theme.type.label)
        .lineSpacing(theme.space.s1)
        .foregroundStyle(hintIsError ? theme.color.danger : theme.color.textSecondary)
        .padding(hintIsError ? theme.space.s3 : 0)
        .frame(maxWidth: .infinity, alignment: hintIsError ? .leading : .center)
        .background {
            if hintIsError {
                RoundedRectangle(cornerRadius: theme.radius.l)
                    .fill(theme.color.dangerSurface).strokeBorder(theme.color.dangerBorder)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chipText: String {
        if case .live(.listening) = phase, isMuted { return "mic muted" }
        if waitingWake { return "say \"\(wakePhrase)\"" }
        return switch phase {
        case .idle: "ready"
        case .connecting: "connecting…"
        case .reconnecting: "reconnecting…"
        case .live(.listening): "listening"
        case .live(.thinking): "\(name) is working"
        case .live(.speaking): "\(name) is speaking"
        case let .ended(ending): isFailure(ending) ? "could not call" : "call ended"
        }
    }

    private var hintText: String {
        if case .live(.listening) = phase, isMuted { return "your microphone is muted." }
        return switch phase {
        case .idle: "Tap call to start."
        case .connecting: "setting up the call."
        case .reconnecting: "wait before speaking. if this lasts, check that tailscale is connected."
        case .live(.listening): listeningHint
        case .live(.thinking): isMuted ? "unmute to keep talking." : "you can keep talking."
        case .live(.speaking): "speech is ignored until \(name) finishes."
        case let .ended(ending): isFailure(ending) ? ending.message : endedHint(ending)
        }
    }

    /// What sends a turn, and with the wake switch on, the phrase that opens one (the page's `autoListening`).
    private var listeningHint: String {
        guard let commands else { return "go ahead. stop for a moment to send." }
        let send = commandWords.sendHint
        if !commands.wake { return "go ahead. stop for a moment, or say \(send) to send now." }
        if commands.waiting { return "nothing is sent until you say \"\(wakePhrase)\"." }
        return commands.pauseSends ? "say \(send), or stop for a moment, to send." : "say \(send) to send - stopping won't."
    }

    private var hintIsError: Bool {
        if case let .ended(ending) = phase { return isFailure(ending) }
        return false
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: theme.space.s2) {
            if hintIsError {
                HStack(spacing: theme.space.s3) {
                    optionsControl.fixedSize()
                    Button { Task { await startDisplayedCall() } } label: {
                        Text("Call again").textRole(theme.type.body, theme.weight.medium)
                            .frame(maxWidth: .infinity, minHeight: theme.control.touchTarget)
                            .background(theme.color.accent, in: Capsule())
                            .foregroundStyle(theme.color.onAccent)
                    }
                    .accessibilityIdentifier(AXID.keysCall)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { controlButtons }
                    ScrollView(.horizontal) { HStack { controlButtons } }
                }
            }
            if hintIsError, let minimize {
                Button(action: minimize) {
                    Text("Back to conversation").textRole(theme.type.body, theme.weight.medium)
                        .frame(maxWidth: .infinity, minHeight: theme.control.touchTarget)
                        .background(theme.color.secondaryFill, in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var controlButtons: some View {
        Button { call.setMuted(!isMuted) } label: {
            CallControlLabel(title: isMuted ? "Unmute" : "Mute", symbol: isMuted ? "mic.slash" : "mic")
        }
        .disabled(!isCallActive)
        .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
        .accessibilityValue(micLabel)
        optionsControl

        Button {
            if isCallActive { call.hangUp() } else { Task { await startDisplayedCall() } }
        } label: {
            CallControlLabel(title: callKey.title.capitalized, symbol: isCallActive ? "phone.down.fill" : "phone.fill",
                             danger: isCallActive)
        }
        .accessibilityIdentifier(AXID.keysCall)
        .accessibilityLabel(callKey.spoken)
        .disabled(isSettingUp && !cancelArmed)
    }

    private var optionsControl: some View {
        Button {
            optionsVoice = voiceService.map { VoiceSettingsModel(service: $0) }
            presentsCallOptions = true
        } label: {
            CallControlLabel(title: "Options", symbol: "ellipsis")
        }
        .accessibilityIdentifier(AXID.controlsOptions)
    }

    /// A redial starts from the conversation as the list has it now; the host still decides whether it may call.
    private func startDisplayedCall() async {
        let paired = pairedTarget.paired
        let chat = ChatController.shared
        let live = chat.host == paired.host ? chat.conversation(paired.conversation.id) : nil
        _ = await call.start(target: CallTarget(paired: PairedCallTarget(host: paired.host, deviceId: paired.deviceId,
            conversation: live ?? paired.conversation), service: pairedTarget.service))
    }

    private var voiceService: (any VoicePickerService)? {
        call.liveVoiceService ?? pairedTarget.voicePickerService
    }

    private var callOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack {
                    VStack(alignment: .leading, spacing: theme.space.s1) {
                        Text("Call options").textRole(theme.type.headline, theme.weight.bold)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(displayName) · this call").textRole(theme.type.label)
                            .foregroundStyle(theme.color.textSecondary)
                    }
                    Spacer()
                    GlassIconButton(title: "Close", systemImage: "xmark") { presentsCallOptions = false }
                }
                SettingsSection {
                    Button {
                        guard let model = optionsVoice else { return }
                        let picker = model.loading ? VoiceSettingsModel(service: model.service) : model
                        pendingVoice = VoiceTarget(model: picker, agentName: displayName, callID: call.liveCallID)
                        presentsCallOptions = false
                    } label: {
                        SettingsRow(title: "Voice", icon: "waveform", detail: optionsVoiceName, navigates: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(optionsVoice == nil)
                    .accessibilityIdentifier(AXID.optionsVoice)
                    Divider().overlay(theme.color.border)
                        .padding(.leading, theme.space.s4 + theme.control.glassIcon + theme.space.s3)
                    Toggle(isOn: Binding(get: { commands?.typing ?? call.settingsPicks.typing }, set: { typing in
                        settingsBusy = true
                        Task {
                            await call.updateSettings(typing: typing)
                            settingsBusy = false
                        }
                    })) {
                        SettingsRow(title: "Typing sound", icon: "keyboard", subtitle: "Quiet keys while \(displayName) works on your turn")
                    }
                    .toggleStyle(.switch).tint(theme.color.accent)
                    .padding(.trailing, theme.space.s4)
                    .disabled(settingsBusy || !canChangeTyping)
                    .accessibilityIdentifier(AXID.optionsTyping)
                }
            }
            .foregroundStyle(theme.color.textPrimary)
            .padding(theme.space.s4)
            .padding(.vertical, theme.space.s2)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { optionsHeight = $0.rounded(.up) }
        }
        .task(id: voiceService?.identity) {
            if optionsVoice?.service.identity != voiceService?.identity {
                optionsVoice = voiceService.map { VoiceSettingsModel(service: $0) }
            }
            if call.liveCallID == nil || call.liveVoice == nil { await optionsVoice?.load() }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(optionsHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(theme.color.surfaceSheet)
        .preferredColorScheme(.dark)
    }

    private var optionsVoiceName: String {
        if let live = call.liveVoice, call.liveCallID != nil {
            return VoiceLabel(live.activeDetails, providerDefault: live.active.voice == nil).title
        }
        if let view = optionsVoice?.view {
            return VoiceLabel(view.details?.effective, providerDefault: view.effective.voice == nil).title
        }
        return optionsVoice?.loading == true ? "Loading…" : "Unavailable"
    }

    private var canChangeTyping: Bool {
        if commands != nil { return isLive }
        switch phase {
        case .idle, .ended: return true
        case .connecting, .live, .reconnecting: return false
        }
    }

    /// The page's primary key: what it shows, and what VoiceOver says.
    private var callKey: (title: String, spoken: String) {
        if onCall { return ("end", "End call") }
        if isCallActive { return ("cancel", "Cancel call") }
        if case .ended = phase { return ("call again", "Call again") }
        return ("call", "Call")
    }

    /// Dan's reply is never listened over: the line hears nothing while he speaks, apart from the caller's mute.
    private var pausedForReply: Bool { phase == .live(.speaking) && !isMuted }

    private var micLabel: String {
        if isCallActive, isMuted { return "mic muted" }
        if pausedForReply { return "paused for reply" }
        return onCall ? "mic on" : "mic off"
    }

    private var callLabel: String {
        switch phase {
        case .live: "on call"
        case .reconnecting where onCall: "on call"
        case .connecting, .reconnecting: "connecting"
        case let .ended(ending) where isFailure(ending): "not connected"
        default: "ready"
        }
    }

    // MARK: State

    private var name: String { displayName.lowercased() }
    private var phase: CallController.Phase { preview?.phase ?? call.phase }
    private var isMuted: Bool { preview?.muted ?? call.isMuted }
    private var liveSince: Date? { preview.map(\.liveSince) ?? call.liveSince }
    private var endedAt: Date? { preview.map(\.endedAt) ?? call.endedAt }
    private var thinkingSince: Date? { preview.map(\.thinkingSince) ?? call.thinkingSince }

    private var commands: CommandSettings? {
        if let preview { return preview.commands }
        return call.commands
    }

    private var commandWords: CommandWords { preview == nil ? call.commandWords : .builtIn }

    /// The phrase that opens a turn with the wake switch on, as the worker names it, in its written case.
    private var wakePhrase: String { commands?.phrase ?? "Hey \(displayName)" }

    /// Auto mode with the wake switch, before the phrase: the line is open but nothing is taken.
    private var waitingWake: Bool {
        guard case .live(.listening) = phase, !isMuted else { return false }
        return commands?.waiting == true
    }

    private var isLive: Bool {
        if case .live = phase { return true }
        return false
    }

    /// Live, or reconnecting a call that was: a reconnect mid-call still reads as on the call.
    private var onCall: Bool { isLive || (phase == .reconnecting && liveSince != nil) }

    /// Connecting, or reconnecting before the call ever went live.
    private var isSettingUp: Bool { isCallActive && !onCall }

    private var isCallActive: Bool {
        switch phase {
        case .connecting, .live, .reconnecting: true
        case .idle, .ended: false
        }
    }

    private func isFailure(_ ending: CallController.Ending) -> Bool { CallController.isFailure(ending, liveSince: liveSince) }

    /// How long the call ran and why it ended (the page's `endedHint`).
    private func endedHint(_ ending: CallController.Ending) -> String {
        let length = liveSince.map { (endedAt ?? .now).timeIntervalSince($0) } ?? 0
        let message = ending.message
        let summary = ending.cause == .caller
            ? "thanks for calling"
            : String(message.hasSuffix(".") ? message.dropLast() : Substring(message)).lowercased()
        return "\(clock(length)) · \(summary)."
    }
}

/// `05:07` for the call's clock, `5:07` beside a line or a wait.
private func clock(_ seconds: TimeInterval, pad: Bool = true) -> String {
    let total = max(0, Int(seconds))
    let minutes = total / 60
    let rest = String(format: "%02d", total % 60)
    return pad ? String(format: "%02d:", minutes) + rest : "\(minutes):\(rest)"
}

struct CallStateChip: View {
    @Environment(\.theme) private var theme
    let label: String
    let dot: Color

    var body: some View {
        HStack(spacing: theme.space.s1_5) {
            Circle().fill(dot).frame(width: theme.space.s2, height: theme.space.s2)
            Text(label).textRole(theme.type.footnote, theme.weight.medium)
        }
        .padding(.horizontal, theme.space.s3).frame(minHeight: theme.space.s8)
        .background(theme.color.surfaceGrouped, in: Capsule())
    }
}

private struct CallControlLabel: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    let title: String
    let symbol: String
    var danger = false

    var body: some View {
        VStack(spacing: theme.space.s2) {
            Image(systemName: symbol)
                .font(.system(size: theme.space.s6, weight: theme.weight.medium))
                .foregroundStyle(danger ? theme.color.onAccent : theme.color.icon)
                .frame(width: theme.space.s8 * 2, height: theme.space.s8 * 2)
                .background(danger ? theme.color.callEnd : theme.color.glass, in: Circle())
                .overlay { Circle().strokeBorder(danger ? theme.color.callEnd : theme.color.composerBorder) }
            Text(title).textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
        }
        .frame(maxWidth: .infinity).opacity(enabled ? 1 : 0.5)
    }
}

/// them and not the whole screen.
private struct TranscriptPane: View {
    @Environment(\.theme) private var theme
    @Environment(CallController.self) private var call
    /// A preview's stand-in, shown in place of the call's transcript.
    let standIn: Transcript?
    let agentName: String
    let start: Date?
    let awake: Bool
    let frozen: Bool
    /// What the empty transcript says; nil for none.
    let empty: String?

    var body: some View {
        let transcript = standIn ?? call.transcript
        VStack(alignment: .leading, spacing: theme.space.s2_5) {
            if let notice = Self.deliveryNotice(transcript) {
                Text(notice)
                    .textRole(theme.type.caption)
                    .spacing(0.04, size: 12)
                    .foregroundStyle(theme.color.danger)
                    .padding(.horizontal, theme.space.s0_5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TranscriptConsole(
                transcript: transcript, agentName: agentName, start: start, awake: awake, frozen: frozen, empty: empty
            )
        }
    }

    /// The newest delivery mark decides: a lost turn stays on screen until a later one is sent.
    private static func deliveryNotice(_ transcript: Transcript) -> String? {
        guard case let .lost(reason) = transcript.lines.last(where: { line in
            guard let mark = line.mark else { return false }
            if case .dropped = mark { return false }
            return true
        })?.mark else { return nil }
        let notice = switch reason {
        case .stt: "couldn’t transcribe that - please repeat."
        case .empty: "no words heard - please repeat."
        case .rejected: "turn not accepted."
        case .rateLimited: "too many turns - wait before repeating."
        // The host never confirmed the turn, which is not the same as dropped: repeating it blindly could ask twice.
        case .timeout: "delivery not confirmed - check the chat before repeating."
        case nil: "not sent."
        }
        return "last turn: \(notice)"
    }
}

// MARK: - Transcript

/// The live transcript inside the screen, as the page's console draws it: no bubbles, a speaker row over each
/// block, history a step dimmer than the newest words. It follows the newest line until the reader scrolls up.
private struct TranscriptConsole: View {
    @Environment(\.theme) private var theme
    let transcript: Transcript
    let agentName: String
    /// When the call went live; line times count from here.
    let start: Date?
    /// The worker still takes the turn the wake phrase opened.
    let awake: Bool
    /// A preview's stand-in transcript whose newest words keep their caret.
    let frozen: Bool
    let empty: String?

    @State private var following = true
    /// The line at the top of the view: kept in place when the oldest lines drop off at the cap.
    @State private var topLine: Int?
    private static let bottom = "bottom"

    var body: some View {
        if transcript.lines.isEmpty, let empty {
            VStack(spacing: theme.space.s1) {
                Text("Nothing said yet")
                    .textRole(theme.type.footnote, theme.weight.medium)
                    .foregroundStyle(theme.color.textPrimary)
                Text(empty)
                    .textRole(theme.type.footnote)
                    .foregroundStyle(theme.color.textSecondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, theme.space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if transcript.lines.isEmpty {
            Color.clear
        } else {
            log
        }
    }

    private var log: some View {
        let lines = transcript.lines
        let live = transcript.liveLineIDs
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: theme.space.s4) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            if line.kind == .unheard {
                                UnheardNote(agentName: agentName)
                            } else {
                                CaptionLine(
                                    line: line,
                                    live: live.contains(line.id),
                                    continued: transcript.continuesAbove(index),
                                    note: note(index),
                                    speaker: line.speaker == .caller ? "you" : agentName.lowercased(),
                                    time: time(line.at),
                                    awake: awake,
                                    caretSince: line.id == transcript.streamingLineID ? transcript.lastDeltaAt : nil,
                                    frozen: frozen
                                )
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(EdgeInsets(top: theme.space.s4, leading: theme.space.s1, bottom: theme.space.s1, trailing: theme.space.s1))
                    Color.clear.frame(height: 0).id(Self.bottom)
                }
            }
            .scrollPosition(id: $topLine, anchor: .top)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollSpot.self) { geometry in
                ScrollSpot(
                    top: geometry.contentOffset.y,
                    height: geometry.containerSize.height,
                    atBottom: geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height + geometry.contentInsets.bottom - 2
                )
            } action: { old, new in
                // Content growing never moves the reader: only scrolling up detaches, and reaching the end again re-attaches.
                if new.atBottom {
                    following = true
                } else if new.top < old.top - 0.5, new.height == old.height {
                    following = false
                } else if following, new.height != old.height {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .onChange(of: lines) {
                if following { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 16)
                    Color.black
                }
            }
            .overlay(alignment: .bottom) {
                if !following {
                    Button("newest", systemImage: "arrow.down") {
                        following = true
                        proxy.scrollTo(Self.bottom, anchor: .bottom)
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: theme.type.footnote.size, weight: theme.weight.semibold))
                    .foregroundStyle(theme.color.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(theme.color.glass).shadow(color: theme.color.shadow, radius: theme.space.s1, y: theme.space.s0_5))
                    .overlay(Circle().strokeBorder(theme.color.border, lineWidth: 1))
                    .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
                    .contentShape(Rectangle())
                    .padding(.bottom, theme.space.s2_5)
                }
            }
        }
    }

    private struct ScrollSpot: Equatable {
        let top: CGFloat
        let height: CGFloat
        let atBottom: Bool
    }

    /// A caller turn's number on its first line only; on an agent line, what its message answers.
    private func note(_ index: Int) -> String? {
        let line = transcript.lines[index]
        switch line.speaker {
        case .caller:
            guard let turn = line.turn else { return nil }
            let previous = index > 0 ? transcript.lines[index - 1] : nil
            if let previous, previous.speaker == .caller, previous.turn == turn { return nil }
            return "turn \(turn)"
        case .agent:
            return switch line.answers {
            case let .turn(turn, part?): "reply to turn \(turn) · part \(part)"
            case let .turn(turn, nil): "reply to turn \(turn)"
            case .unprompted: "unprompted"
            case nil: nil
            }
        }
    }

    private func time(_ at: Date) -> String { clock(at.timeIntervalSince(start ?? at), pad: false) }
}

private struct UnheardNote: View {
    @Environment(\.theme) private var theme
    let agentName: String

    var body: some View {
        Text("not heard - \(agentName.lowercased()) was speaking.")
            .textRole(theme.type.caption)
            .foregroundStyle(theme.color.textSecondary)
            .padding(.vertical, theme.space.s1)
            .padding(.horizontal, theme.space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { theme.color.accentText.frame(width: 2) }
            .padding(.vertical, theme.space.s0_5)
    }
}

private struct CaptionLine: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let line: Transcript.Line
    /// Part of the newest block: full contrast. History steps back by colour.
    let live: Bool
    /// Carries on the caller line above: no speaker row of its own.
    let continued: Bool
    let note: String?
    let speaker: String
    let time: String
    let awake: Bool
    /// When the line last got words, if it is the one that did.
    let caretSince: Date?
    let frozen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s1_5) {
            if !continued { header }
            if caretSince != nil, frozen {
                words(caret: true)
            } else if let caretSince {
                let end = caretSince.addingTimeInterval(Transcript.streamingWindow)
                TimelineView(.explicit(caretChanges(from: caretSince, to: end))) { context in
                    let lit = reduceMotion || context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.5
                    words(caret: context.date < end && lit)
                }
                .id(caretSince)
            } else {
                words(caret: false)
            }
        }
        .padding(.vertical, theme.space.s1_5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The only moments the caret changes: when the words came, each blink edge, and when the window closes.
    private func caretChanges(from start: Date, to end: Date) -> [Date] {
        var changes = [start]
        if !reduceMotion {
            var edge = (start.timeIntervalSinceReferenceDate * 2).rounded(.down) / 2 + 0.5
            while edge < end.timeIntervalSinceReferenceDate {
                changes.append(Date(timeIntervalSinceReferenceDate: edge))
                edge += 0.5
            }
        }
        return changes + [end]
    }

    private var header: some View {
        FlowLayout(spacing: theme.space.s2, lineSpacing: theme.space.s1) {
            Text(speaker)
                .foregroundStyle(theme.color.textSecondary)
            Text(time).foregroundStyle(theme.color.textSecondary)
            if let note { Text(note).foregroundStyle(theme.color.textSecondary) }
            if line.wake {
                if line.wakeOnly {
                    MarkTag(text: "wake phrase", style: .wake)
                } else {
                    let listening = line.mark == nil && awake
                    MarkTag(text: listening ? "heard - listening" : "heard", style: listening ? .awake : .wake)
                }
            }
            if let mark = line.mark { MarkTag(text: label(mark), style: style(mark)) }
            if line.unspoken { MarkTag(text: "reply not spoken", style: .lost) }
            if line.preWake { MarkTag(text: "words before the wake phrase ignored", style: .dropped) }
        }
        .textRole(theme.type.micro)
        .spacing(0.04, size: 11)
    }

    private func words(caret: Bool) -> some View {
        let empty = line.text.isEmpty
        let placeholder = switch line.mark {
        case .lost(.stt), .lost(.empty): "Speech could not be transcribed."
        default: "No transcript."
        }
        var words = Text(empty ? placeholder : line.text).foregroundStyle(empty ? theme.color.textSecondary : ink)
        if case .dropped(.discarded) = line.mark {
            words = words.strikethrough(color: ink.opacity(0.45))
        }
        let text = caret ? Text("\(words)\(Text(caretImage).baselineOffset(-2.25))") : words
        return text
            .textRole(line.speaker == .caller ? theme.type.headline : theme.type.title,
                      line.speaker == .caller ? theme.weight.regular : theme.weight.medium)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var ink: Color {
        var color: Color
        if case .lost = line.mark {
            color = theme.color.textPrimary
        } else if line.unspoken {
            color = theme.color.textPrimary
        } else if case .dropped = line.mark {
            color = theme.color.textSecondary
        } else if line.wakeOnly {
            color = theme.color.textSecondary
        } else {
            color = line.speaker == .caller ? theme.color.textSecondary : theme.color.textPrimary
        }
        // Interim caller words step back until the transcription's final replaces them.
        if line.speaker == .caller, !line.isFinal, line.mark == nil { color = color.opacity(0.6) }
        return color
    }

    /// A block 0.55em wide and 1em tall, 3pt after the last word.
    private var caretImage: Image {
        Image(size: CGSize(width: 11.25, height: 15)) { context in
            context.fill(Path(CGRect(x: 3, y: 0, width: 8.25, height: 15)), with: .color(theme.color.accentText.opacity(0.9)))
        }
    }

    private func label(_ mark: Transcript.Mark) -> String {
        switch mark {
        case .sent: "sent"
        case .dropped(.command): line.command?.kind == .discard ? "nothing to discard" : "nothing to send"
        case .dropped(.asleep): "went back to sleep"
        case .dropped(.unaddressed): "ignored · no wake phrase"
        case .dropped(.discarded): "discarded"
        case .lost(.timeout): "not confirmed"
        case let .lost(reason?): "not sent · \(Self.lostReason(reason))"
        case .lost(nil): "not sent"
        }
    }

    private static func lostReason(_ reason: TurnStatus.Reason) -> String {
        switch reason {
        case .stt: "couldn’t transcribe"
        case .empty: "no words heard"
        case .rejected: "not accepted"
        case .rateLimited: "too many turns"
        case .timeout: "not confirmed"
        }
    }

    private func style(_ mark: Transcript.Mark) -> MarkTag.Style {
        switch mark {
        case .sent: .sent
        case .dropped: .dropped
        case .lost: .lost
        }
    }
}

/// A turn's mark beside the speaker: outlined in its colour, the wake that is still listening filled orange.
private struct MarkTag: View {
    @Environment(\.theme) private var theme
    enum Style { case sent, dropped, lost, wake, awake }
    let text: String
    let style: Style

    var body: some View {
        let ink: Color = switch style {
        case .sent: theme.color.textSecondary
        case .dropped: theme.color.textSecondary
        case .lost: theme.color.danger
        case .wake: theme.color.textPrimary
        case .awake: theme.color.surface
        }
        let boxed = style != .sent
        Text(text)
            .foregroundStyle(ink)
            .lineHeight(.multiple(factor: 1.5))
            .padding(.horizontal, boxed ? theme.space.s1_5 : 0)
            .background {
                switch style {
                case .sent: EmptyView()
                case .awake: RoundedRectangle(cornerRadius: 3).fill(theme.color.accentText)
                default: RoundedRectangle(cornerRadius: 3).strokeBorder(ink, lineWidth: 1)
                }
            }
    }
}

// MARK: - Preview

/// A stand-in call for Simulator screenshots, from `HEYDAN_PREVIEW_PHASE`; nothing outside DEBUG Simulator builds.
private struct Preview {
    var phase: CallController.Phase
    var muted = false
    var transcript = Transcript()
    var commands: CommandSettings?
    /// The newest words keep their caret, as if still arriving.
    var caret = false
    /// An ended call that had been live.
    var wasLive = false
    let start = Date(timeIntervalSinceNow: -83)
    private let shownAt = Date.now

    var liveSince: Date? {
        switch phase {
        case .live, .reconnecting: start
        case .ended: wasLive ? start : nil
        case .idle, .connecting: nil
        }
    }

    var endedAt: Date? { wasLive ? shownAt : nil }
    var thinkingSince: Date? { phase == .live(.thinking) ? start.addingTimeInterval(71) : nil }

    @MainActor static func fromEnvironment() -> Preview? {
        #if DEBUG && targetEnvironment(simulator)
            guard var name = ScreenCaptureFixture.phase ?? ProcessInfo.processInfo.environment["HEYDAN_PREVIEW_PHASE"] else { return nil }
            // "thinking-muted", "speaking-muted": the same stage with the microphone muted.
            let mutedVariant = name.hasSuffix("-muted")
            if mutedVariant { name.removeLast("-muted".count) }
            let phase: (CallController.Phase, muted: Bool)? = switch name {
            case "idle": (.idle, false)
            case "connecting": (.connecting, false)
            case "reconnecting": (.reconnecting, false)
            case "listening", "waiting": (.live(.listening), false)
            case "thinking": (.live(.thinking), false)
            case "speaking": (.live(.speaking), false)
            case "muted": (.live(.listening), true)
            case "ended": (.ended(.byCaller), false)
            case "left": (.ended(.init(cause: .remote, message: "Dan left the call.")), false)
            case "failed": (.ended(.failure(.pairedTransport)), false)
            default: nil
            }
            guard let phase else { return nil }
            var preview = Preview(phase: phase.0, muted: phase.muted || mutedVariant)
            let stage: Stage? = switch name {
            case "waiting": .waiting
            case "thinking": .thinking
            case "speaking": .speaking
            case "listening", "muted", "reconnecting", "ended", "left": .listening
            default: nil
            }
            guard let stage else { return preview }
            preview.transcript = sample(stage, start: preview.start)
            preview.caret = name == "listening" || name == "speaking"
            if case .ended = phase.0 {
                preview.wasLive = true
                preview.transcript.end()
            } else {
                var commands = CommandSettings(picks: SettingsPicks(wake: true, pauseSends: false, typing: true))
                commands.waiting = stage == .waiting
                preview.commands = commands
            }
            return preview
        #else
            return nil
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
        /// How far into the sample call the screenshot stops.
        private enum Stage { case waiting, thinking, speaking, listening }

        private static func sample(_ stage: Stage, start: Date) -> Transcript {
            var transcript = Transcript()
            func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
            func said(_ segment: String, _ text: String, final: Bool = true, at seconds: TimeInterval) {
                transcript.caption(segment: segment, text: text, isFinal: final, fromCaller: true, at: at(seconds))
            }
            func spoke(_ segment: String, _ text: String, at seconds: TimeInterval) {
                transcript.caption(segment: segment, text: text, isFinal: true, fromCaller: false, at: at(seconds))
            }
            if FixtureContent.capturing {
                said("caller", FixtureContent.caller, at: 5)
                transcript.apply(.status(TurnStatus(turn: 1, status: .sent, text: FixtureContent.caller)), at: at(6))
                transcript.apply(ReplyInfo(reply: 1, turn: 1), at: at(9))
                spoke("reply", FixtureContent.reply, at: 9)
                return transcript
            }
            let backup = "Can you check whether the backup ran last night?"
            said("SG_1", backup, at: 5)
            transcript.apply(.status(TurnStatus(turn: 1, status: .sent, text: backup)), at: at(6))
            transcript.apply(ReplyInfo(reply: 1, turn: 1), at: at(9))
            spoke("SA_1", "Checking the backup log now.", at: 9)
            spoke("SA_2", "It finished at 3:12 with no errors, 41 gigabytes copied.", at: 12)
            transcript.apply(.unheard, at: at(14))
            transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: true), at: at(20))
            said("SG_2", "So what was the other thing", at: 31)
            transcript.apply(.dropped(DroppedSpeech(.unaddressed, text: "So what was the other thing")), at: at(32))
            if stage == .waiting { return transcript }
            let milk = "Hey Dan, add milk to the shopping list."
            transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: false, heard: 1), at: at(40))
            said("SG_3", milk, at: 41)
            said("SG_4", "Zulu.", at: 44)
            transcript.apply(.status(TurnStatus(turn: 3, status: .sent, text: milk)), at: at(45))
            if stage == .thinking { return transcript }
            transcript.apply(ReplyInfo(reply: 2, turn: 3), at: at(50))
            spoke("SA_3", "Added milk to the shopping list.", at: 50)
            if stage == .speaking { return transcript }
            transcript.apply(wake: WakeState(on: true, pauseSends: false, waiting: false, heard: 2), at: at(77))
            said("SG_5", "Hey Dan, and eggs if we're out", final: false, at: 78)
            return transcript
        }
    #endif
}
