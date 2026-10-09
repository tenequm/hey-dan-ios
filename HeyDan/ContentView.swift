import HeyDanCore
import SwiftUI

struct ContentView: View {
    @Environment(CallController.self) private var call
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSettings = false
    @State private var showsOptions = false
    @State private var voiceTarget: VoiceTarget?
    @State private var pendingVoiceTarget: VoiceTarget?
    @State private var settingsBusy = false
    /// Right after "call" the same key reads "cancel": taps are ignored for a moment so a double tap cannot cancel.
    @State private var cancelArmed = false
    /// The review key action last armed: a key that just changed what it does ignores taps for a moment.
    @State private var leftArmedAs: String?
    @State private var rightArmedAs: String?
    @ScaledMetric private var muteWidth: CGFloat = 124
    @State private var preview = Preview.fromEnvironment()

    private struct VoiceTarget: Identifiable {
        let id = UUID()
        let line: VoiceLine
        let agentName: String
        let callID: UUID?
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            screen
            controls
            keys
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.card.shadow(.inner(color: .white.opacity(0.12), radius: 0, y: 1)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 22, y: 18)
        }
        .padding(8)
        .background(Theme.page.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(isPresented: $showsOptions, onDismiss: {
            guard let target = pendingVoiceTarget else { return }
            pendingVoiceTarget = nil
            voiceTarget = target
        }) { optionsSheet }
        .sheet(item: $voiceTarget) { target in
            VoicePickerSheet(line: target.line, agentName: target.agentName, callID: target.callID)
        }
        .onAppear {
            if preview == nil, call.line == nil {
                showsSettings = true
            }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["HEYDAN_PREVIEW_SETTINGS"] == "1" { showsSettings = true }
            #endif
        }
        .task(id: isSettingUp) {
            cancelArmed = false
            guard isSettingUp else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { cancelArmed = true }
        }
        .task(id: leftIdentity) {
            try? await Task.sleep(for: ReviewView.rearm)
            if !Task.isCancelled { leftArmedAs = leftIdentity }
        }
        .task(id: rightIdentity) {
            try? await Task.sleep(for: ReviewView.rearm)
            if !Task.isCancelled { rightArmedAs = rightIdentity }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text("hey dan")
                    .font(Theme.sans(17, .medium))
                    .spacing(-0.01, size: 17)
                Text(subtitle)
                    .font(Theme.mono(12))
                    .spacing(0.02, size: 12)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            if let liveSince, isCallActive {
                TimelineView(.periodic(from: liveSince, by: 1)) { context in
                    Text(clock(context.date.timeIntervalSince(liveSince)))
                        .font(Theme.mono(14))
                        .monospacedDigit()
                        .spacing(0.04, size: 14)
                }
            }
            Button("settings", systemImage: "gearshape") { showsSettings = true }
                .labelStyle(.iconOnly)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .disabled(isCallActive)
                .opacity(isCallActive ? 0.4 : 1)
        }
    }

    private var badge: some View {
        let pulsing = switch phase {
        case .idle, .connecting, .reconnecting: true
        default: false
        }
        return DotMatrix(pattern: isLive ? Claw.open : Claw.closed)
            .modifier(Breathing(active: pulsing, period: 2 * .pi / 2.2, dimmest: 0.55, brightest: 0.9))
            .frame(width: 46, height: 46)
        .modifier(InsetWell())
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(isLive ? Theme.ok : Theme.ledOff)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(Theme.card, lineWidth: 3))
                .shadow(color: isLive ? Theme.ok.opacity(0.6) : .clear, radius: 3)
                .offset(x: 4, y: -4)
        }
        .animation(.easeInOut(duration: 0.25), value: isLive)
    }

    private var subtitle: AttributedString {
        let lead = switch phase {
        case .idle: "ready to call "
        case .reconnecting where onCall: "on a call with "
        case .connecting, .reconnecting: "calling "
        case .live: "on a call with "
        case let .ended(ending): isFailure(ending) ? "could not call " : "call ended with "
        }
        var agent = AttributedString(name)
        agent.foregroundColor = Theme.orange
        agent.font = Theme.mono(12, medium: true)
        return AttributedString(lead) + agent
    }

    // MARK: Screen

    private var screen: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                chip
                hint
            }
            .padding(EdgeInsets(top: 10, leading: 2, bottom: 12, trailing: 2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Theme.screenRule.frame(height: 1) }
            .overlay(alignment: .bottom) { Theme.screenRule.frame(height: 1) }
            let panel = reviewKeys?.panel
            if let panel {
                DraftPanel(
                    panel: panel,
                    standInWords: preview?.draftWords,
                    note: review.note,
                    keep: keepWords,
                    copyable: review.ended,
                    endCall: reviewKeys?.endable == true && isLive ? { call.hangUp() } : nil
                )
            }
            TranscriptPane(
                standIn: preview?.transcript,
                start: liveSince,
                awake: onCall && commands?.wake == true && commands?.waiting == false,
                frozen: preview?.caret ?? false,
                // A draft on screen is the thing to read: no empty state competes with it.
                empty: panel == nil ? emptyDescription : nil
            )
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
        .frame(maxWidth: .infinity, minHeight: 144, maxHeight: .infinity, alignment: .top)
        .modifier(InsetWell())
    }

    private var emptyDescription: String {
        let agent = call.agentName
        if onCall {
            if review.isOn { return "Sent turns show here." }
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
        let style = chipStyle
        return HStack(spacing: 8) {
            switch style.mark {
            case .none: EmptyView()
            case .pulse: PulseDot(color: style.palette.dot ?? style.palette.ink)
            case .still: PulseDot(color: Theme.stillDot, still: true)
            case .alert: Image(systemName: "exclamationmark.circle").font(.system(size: 15, weight: .semibold))
            }
            let text = reviewReadout.map { asWritten($0.chip, keep: keepWords) } ?? chipText
            if style.shimmer {
                ShimmerText(text: text, base: Theme.think, highlight: Theme.text)
            } else {
                Text(text)
            }
        }
        .font(Theme.mono(17, medium: true))
        .spacing(0.02, size: 17)
        .foregroundStyle(style.palette.ink)
        .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 12))
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 4).fill(style.palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style.palette.outline, lineWidth: 1))
    }

    @ViewBuilder private var hint: some View {
        Group {
            if let rv = reviewReadout {
                if reviewPhase == .thinking, let thinkingSince {
                    TimelineView(.periodic(from: thinkingSince, by: 1)) { context in
                        let waited = Int(context.date.timeIntervalSince(thinkingSince))
                        Text(asWritten(reviewView(waited: waited)?.hint ?? rv.hint, keep: keepWords))
                    }
                } else {
                    Text(asWritten(rv.hint, keep: keepWords))
                }
            } else if case .live(.thinking) = phase, let thinkingSince {
                TimelineView(.periodic(from: thinkingSince, by: 1)) { context in
                    let waited = clock(context.date.timeIntervalSince(thinkingSince), pad: false)
                    Text("\(isMuted ? "unmute to keep talking" : "you can keep talking") · waiting \(waited)")
                }
            } else {
                Text(hintText)
            }
        }
        .font(Theme.mono(13))
        .lineSpacing(4)
        .foregroundStyle(hintIsError ? Theme.error : Theme.screenDim)
        .frame(minHeight: 36, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private struct ChipStyle {
        enum Mark { case none, pulse, still, alert }
        var palette = ChipPalette.quiet
        var mark = Mark.none
        var shimmer = false
    }

    private var chipStyle: ChipStyle {
        if let rv = reviewReadout { return reviewChipStyle(rv.tone) }
        if case .live(.listening) = phase, isMuted { return ChipStyle(mark: .still) }
        // Waiting for the wake phrase: the line is open but nothing is taken.
        if waitingWake { return ChipStyle(mark: .still) }
        switch phase {
        case .live(.speaking):
            return ChipStyle(palette: .speaking, mark: .pulse)
        case .live(.listening):
            return ChipStyle(palette: .you, mark: .pulse)
        case .live(.thinking):
            return ChipStyle(palette: .thinking, mark: .pulse, shimmer: true)
        case let .ended(ending) where isFailure(ending):
            return ChipStyle(palette: .error, mark: .alert)
        default:
            return ChipStyle()
        }
    }

    /// The page's readout tones; one with no tone of its own pulses orange while the call is live.
    private func reviewChipStyle(_ tone: ReviewView.Tone) -> ChipStyle {
        switch tone {
        case .you: ChipStyle(palette: .you, mark: .pulse)
        case .off: ChipStyle(mark: .still)
        case .think: ChipStyle(palette: .thinking, mark: .pulse, shimmer: true)
        case .error: ChipStyle(palette: .error, mark: .alert)
        case .idle, .ended: ChipStyle()
        case .none: isLive ? ChipStyle(palette: .speaking, mark: .pulse) : ChipStyle()
        }
    }

    private var chipText: String {
        if switchingToReview { return asWritten("Switching to \(Review.modeName(.review))", keep: keepWords) }
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
        case .idle: hasLine ? "press the action button or tap call." : "add your call link in settings."
        case .connecting: "setting up the call."
        case .reconnecting: "wait before speaking. if this lasts, check that tailscale is connected."
        case .live(.listening): listeningHint
        case .live(.thinking): isMuted ? "unmute to keep talking." : "you can keep talking."
        case .live(.speaking): "speech is ignored until \(name) finishes."
        case let .ended(ending): isFailure(ending) ? ending.message.lowercased() : endedHint(ending)
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
        VStack(spacing: 4) {
            GlassEffectContainer(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { controlButtons }
                    VStack(spacing: 8) { controlButtons }
                }
            }
            .controlSize(.large)
            .buttonSizing(.flexible)
            .buttonBorderShape(.capsule)
            .font(Theme.sans(14, .medium))
            .tint(Theme.text)
            if reviewKeys?.panel == nil, let note = review.note {
                Text(asWritten(note, keep: keepWords))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var controlButtons: some View {
        Menu {
            Picker("Turn mode", selection: Binding(
                get: { review.mode },
                set: { mode in Task { await call.setTurnMode(mode) } }
            )) {
                ForEach([TurnMode.auto, .review], id: \.self) { mode in
                    LabeledContent {
                        Text(modeCaption(mode)).lineLimit(1)
                    } label: {
                        Text(mode == .auto ? "Hands-free" : Review.modeName(mode))
                    }
                    .tag(mode)
                    .disabled(mode == .review && !review.available && review.mode != .review)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(modeLabel)
                    .modifier(Breathing(active: pendingMode != nil && !reduceMotion, period: 1.4, dimmest: 0.55))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(modeDisabled ? Theme.muted : Theme.text)
        }
        .buttonStyle(.glass)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(modeDisabled)
        .accessibilityIdentifier(AXID.controlsMode)
        .accessibilityLabel("Turn mode")
        .accessibilityValue(modeLabel)
        .accessibilityHint(modeCaption(pendingMode ?? review.mode))

        Button {
            guard let line = call.liveLine ?? call.line else { return }
            let target = VoiceTarget(line: line, agentName: call.agentName, callID: call.liveCallID)
            if showsOptions {
                pendingVoiceTarget = target
                showsOptions = false
            } else {
                voiceTarget = target
            }
        } label: {
            Text("Voice")
                .foregroundStyle(call.liveLine == nil && call.line == nil ? Theme.muted : Theme.text)
        }
        .buttonStyle(.glass)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(call.liveLine == nil && call.line == nil)
        .accessibilityIdentifier(AXID.controlsVoice)
        .accessibilityLabel("Voice")
        .accessibilityHint("Choose \(call.agentName)'s voice for this line.")

        Button("Options") { showsOptions = true }
            .buttonStyle(.glass)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier(AXID.controlsOptions)
            .accessibilityLabel("Call options")
            .accessibilityHint("Change voice commands and the typing sound.")
    }

    private var pendingMode: TurnMode? { review.pending?.op == .mode ? review.pending?.to : nil }

    private var modeLabel: String {
        pendingMode == nil ? (review.mode == .auto ? "Hands-free" : Review.modeName(review.mode)) : "Switching..."
    }

    private var modeDisabled: Bool {
        phase == .connecting || (reviewKeys.map(\.modeDisabled) ?? (review.pending != nil || phase == .reconnecting))
    }

    private func modeCaption(_ mode: TurnMode) -> String {
        Review.modeCaption(
            mode, commands: commands != nil || !isLive, words: commandWords,
            wake: commands?.wake ?? call.settingsPicks.wake,
            pauseSends: commands?.pauseSends ?? call.settingsPicks.pauseSends
        )
    }

    private var optionsSheet: some View {
        NavigationStack {
            Form {
                if let shown = shownSettings {
                    let enabled = shown.enabled && !settingsBusy
                    if review.mode == .auto, reviewKeys == nil {
                        Section("Voice commands") {
                            Toggle("wait for \"\(wakePhrase)\"", isOn: settingBinding(shown.wake) { change(wake: $0) })
                                .frame(minHeight: 44)
                                .accessibilityIdentifier(AXID.optionsWake)
                                .accessibilityHint("Nothing is sent until you say \(wakePhrase); then say \(CommandWords.join(commandWords.sendHints, quoted: false)) to send.")
                            if shown.wake {
                                Toggle("a pause also sends", isOn: settingBinding(shown.pauseSends) { change(pauseSends: $0) })
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier(AXID.optionsPauseSends)
                                    .accessibilityHint("After the wake phrase a pause sends too, not only \(CommandWords.join(commandWords.sendHints, quoted: false)).")
                            }
                        }
                        .disabled(!enabled)
                    }
                    Section {
                        Toggle("typing sound", isOn: settingBinding(shown.typing) { change(typing: $0) })
                            .frame(minHeight: 44)
                            .accessibilityIdentifier(AXID.optionsTyping)
                            .accessibilityHint("A quiet keyboard sound while the agent works on your turn.")
                    }
                    .disabled(!enabled)
                } else {
                    Section {
                        Text("Options are unavailable until the voice service shares its settings.")
                            .foregroundStyle(Theme.muted)
                    }
                }
                if review.mode == .auto, reviewKeys == nil {
                    Section("Spoken commands") {
                        Text(commandWords.explainer)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let note = review.note {
                    Section {
                        Text(asWritten(note, keep: keepWords)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .font(Theme.sans(16))
            .toggleStyle(.switch)
            .tint(Theme.orange)
            .navigationTitle("Call options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { showsOptions = false }
                        .accessibilityLabel("Close")
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .controlSize(.large)
            .buttonSizing(.flexible)
            .buttonBorderShape(.capsule)
            .buttonStyle(.glass)
        }
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private var shownSettings: (wake: Bool, pauseSends: Bool, typing: Bool, enabled: Bool)? {
        if let commands { return (commands.wake, commands.pauseSends, commands.typing, isLive) }
        let picks = call.settingsPicks
        switch phase {
        case .idle, .ended: return (picks.wake, picks.pauseSends, picks.typing, true)
        // The worker has not said yet whether it takes commands: the picks stay in view, not changeable.
        case .connecting: return (picks.wake, picks.pauseSends, picks.typing, false)
        case .live, .reconnecting: return nil
        }
    }

    /// Reads what the controller holds; a change only asks, so a refused one never shows as taken.
    private func settingBinding(_ value: Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { new in MainActor.assumeIsolated { set(new) } })
    }

    private func change(wake: Bool? = nil, pauseSends: Bool? = nil, typing: Bool? = nil) {
        settingsBusy = true
        Task {
            await call.updateSettings(wake: wake, pauseSends: pauseSends, typing: typing)
            settingsBusy = false
        }
    }

    // MARK: Keys

    private var keys: some View {
        HStack(alignment: .top, spacing: 14) {
            if let rv = reviewKeys {
                reviewKeyPair(rv)
            } else {
                autoKeys
            }
        }
    }

    /// Review relabels the same two caps: discard is the quiet choice next to send, every other left key keeps the accent.
    @ViewBuilder private func reviewKeyPair(_ rv: ReviewView) -> some View {
        let primaryDisabled = (!isCallActive && !hasLine) || (isSettingUp && !cancelArmed)
        let leftArmed = (leftArmedAs ?? leftIdentity) == leftIdentity
        let rightArmed = (rightArmedAs ?? rightIdentity) == rightIdentity
        VStack(spacing: 6) {
            Button(asWritten(rv.left.label, keep: [])) { run(rv.left.action) }
                .buttonStyle(KeyCapStyle(finish: rv.left.action == .discard ? .light : .orange))
                .accessibilityIdentifier(AXID.keysCall)
                .disabled(rv.left.disabled || !leftArmed || ((rv.left.action == .call || rv.left.action == .cancel) && primaryDisabled))
            keyLabel(Text(review.ended && review.draft != nil ? "draft kept" : callLabel))
        }
        VStack(spacing: 6) {
            Button {
                run(rv.right.action)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: rv.right.action == .done ? "stop.fill" : rv.right.action == .send ? "arrow.up" : "mic.fill")
                        .font(.system(size: rv.right.action == .done ? 12 : 15, weight: .semibold))
                    Text(asWritten(rv.right.label, keep: []))
                }
            }
            .buttonStyle(KeyCapStyle(finish: rv.right.action == .send && !rv.right.disabled ? .orange : rv.right.action == .talk ? .dark : .light))
            .disabled(rv.right.disabled || !rightArmed)
            keyLabel(HStack(spacing: 6) {
                LED(on: rv.capturing || review.micError == .stop)
                Text(asWritten(rv.mic, keep: []))
            })
        }
        .frame(width: min(muteWidth, 180))
    }

    private func run(_ action: ReviewView.Action) {
        switch action {
        case .call: Task { await call.start(lineID: call.shownLineID) }
        case .cancel, .end: call.hangUp()
        case .discard: Task { await call.discard() }
        case .talk: Task { await call.talk() }
        case .done: Task { await call.done() }
        case .send: Task { await call.send() }
        }
    }

    @ViewBuilder private var autoKeys: some View {
        VStack(spacing: 6) {
            Button(callKey.title) {
                if isCallActive { call.hangUp() } else { Task { await call.start(lineID: call.shownLineID) } }
            }
            .buttonStyle(KeyCapStyle(finish: .orange))
            .accessibilityIdentifier(AXID.keysCall)
            .disabled((!isCallActive && !hasLine) || (isSettingUp && !cancelArmed))
            .accessibilityLabel(callKey.spoken)
            keyLabel(Text(callLabel))
        }
        VStack(spacing: 6) {
            Button {
                call.setMuted(!isMuted)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill").font(.system(size: 15))
                    Text(isMuted ? "unmute" : "mute")
                }
            }
            .buttonStyle(KeyCapStyle(finish: isMuted ? .dark : .light))
            // Mid-switch the microphone stays as the switch left it.
            .disabled(!isCallActive || switchingToReview)
            .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
            keyLabel(HStack(spacing: 6) {
                LED(on: onCall && !isMuted && !pausedForReply)
                Text(micLabel)
            })
        }
        .frame(width: min(muteWidth, 180))
    }

    private func keyLabel(_ content: some View) -> some View {
        content
            .font(Theme.mono(11))
            .spacing(0.06, size: 11)
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
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
        default: hasLine ? "ready" : "not connected"
        }
    }

    // MARK: Review mode

    private var review: Review { preview?.review ?? call.review }

    /// Words the lowercase chrome keeps as written: the mode's name and the wake phrase.
    private var keepWords: [String] { [Review.modeName(.review), wakePhrase] }

    /// The page's phase: a reconnect mid-call keeps the call live, with its own overlay.
    private var reviewPhase: ReviewView.Phase {
        switch phase {
        case .idle: .idle
        case .connecting: .connecting
        case .reconnecting: onCall ? .listening : .connecting
        case .live(.listening): .listening
        case .live(.thinking): .thinking
        case .live(.speaking): .talking
        case let .ended(ending): isFailure(ending) ? .error : .ended
        }
    }

    /// Keys, readout and draft panel while review speaks for the call; nil in hands-free. The words being heard stay
    /// out of it: `DraftPanel` reads them itself, so a caption re-renders only the panel.
    private func reviewView(waited: Int = 0) -> ReviewView? {
        guard review.isOn else { return nil }
        return ReviewView(
            phase: reviewPhase, agentName: call.agentName, reconnecting: phase == .reconnecting && onCall, waited: waited,
            review: review, words: "", micOn: onCall && !isMuted
        )
    }

    private var reviewKeys: ReviewView? { reviewView() }

    /// The review view speaks for the readout while the call runs, and for a draft kept after it.
    private var reviewReadout: ReviewView? {
        guard let rv = reviewKeys, reviewPhase != .error else { return nil }
        switch reviewPhase {
        case .ended: return review.ended && review.draft != nil ? rv : nil
        default: return rv
        }
    }

    /// Hands-free asked to become Manual: the worker has not taken it yet.
    private var switchingToReview: Bool { !review.isOn && review.pending?.op == .mode && review.pending?.to == .review }

    private var leftIdentity: String {
        ReviewView.keyIdentity(reviewKeys?.left.action ?? (isCallActive ? .end : nil), draft: review.draft?.id)
    }

    private var rightIdentity: String {
        reviewKeys.map { "\($0.right.action):\(review.draft.map { String($0.id) } ?? "")" } ?? "auto"
    }

    // MARK: State

    private var name: String { call.agentName.lowercased() }
    private var hasLine: Bool { call.line != nil || preview != nil }
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
    private var wakePhrase: String { commands?.phrase ?? "Hey \(call.agentName)" }

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

// MARK: - Review mode

/// The review draft under the readout: dashed, never styled as sent, its header outside its own scroller.
private struct DraftPanel: View {
    @Environment(CallController.self) private var call
    let panel: ReviewView.Panel
    /// A preview's stand-in for the words being heard.
    let standInWords: String?
    /// Why the last operation did not happen, shown on the draft rather than under the switch.
    let note: String?
    let keep: [String]
    /// A draft kept after the call copies.
    let copyable: Bool
    /// Ending the call is on offer next to an open draft (the keys are discard and send); it drops the draft.
    let endCall: (() -> Void)?

    @State private var bodyHeight: CGFloat = 0
    @State private var copied = false
    @ScaledMetric private var maxBody: CGFloat = 220

    private var hearing: Bool { panel.tone == .hearing || panel.tone == .finishing }
    /// The words being heard: the panel's text while a recording is open. Read only here, so a caption re-renders only
    /// the panel.
    private var words: String { standInWords ?? call.draftWords }

    var body: some View {
        let text = hearing ? words : panel.text
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 10, lineSpacing: 2) {
                Text(panel.title)
                    .foregroundStyle(titleInk)
                    .accessibilityAddTraits(.updatesFrequently)
                if let note = panel.note { Text(asWritten(note, keep: keep)) }
                if copyable, !text.isEmpty {
                    PanelButton(title: copied ? "copied" : "copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                }
                if let endCall { PanelButton(title: "end call", systemImage: "phone.down", action: endCall) }
            }
            .font(Theme.mono(11))
            .spacing(0.04, size: 11)
            .foregroundStyle(Theme.screenDim)
            .padding(EdgeInsets(top: 7, leading: 12, bottom: 3, trailing: 12))
            if let note {
                Text(asWritten(note, keep: keep))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.orange)
                    .padding(EdgeInsets(top: 0, leading: 12, bottom: 4, trailing: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Group {
                    if text.isEmpty {
                        Text(panel.tone == .hearing ? "Speak now…" : panel.tone == .finishing ? "…" : "No words.")
                            .foregroundStyle(Theme.screenDim)
                    } else {
                        Text(text)
                            .foregroundStyle(hearing ? Theme.screenSoft : Theme.text)
                            .textSelection(.enabled)
                    }
                }
                .font(Theme.sans(17))
                .lineHeight(.multiple(factor: 1.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 0, leading: 12, bottom: 9, trailing: 12))
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { bodyHeight = $0 }
            }
            // A frozen draft opens at its first word; heard words follow the tail.
            .defaultScrollAnchor(hearing ? .bottom : .top, for: .sizeChanges)
            .defaultScrollAnchor(hearing ? .bottom : .top, for: .initialOffset)
            .id(panel.title)
            .frame(height: min(max(bodyHeight, 34), maxBody))
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.outline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review draft")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var titleInk: Color {
        switch panel.tone {
        case .draft: Theme.orange
        case .failed, .long, .empty: Theme.error
        case .hearing, .finishing: Theme.text
        }
    }
}

private struct PanelButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.text, lineWidth: 1))
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The delivery notice and the transcript: the only views that read the call's transcript, so a caption re-runs
/// them and not the whole screen.
private struct TranscriptPane: View {
    @Environment(CallController.self) private var call
    /// A preview's stand-in, shown in place of the call's transcript.
    let standIn: Transcript?
    let start: Date?
    let awake: Bool
    let frozen: Bool
    /// What the empty transcript says; nil for none.
    let empty: String?

    var body: some View {
        let transcript = standIn ?? call.transcript
        VStack(alignment: .leading, spacing: 10) {
            if let notice = Self.deliveryNotice(transcript) {
                Text(notice)
                    .font(Theme.mono(12))
                    .spacing(0.04, size: 12)
                    .foregroundStyle(Theme.error)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TranscriptConsole(
                transcript: transcript, agentName: call.agentName, start: start, awake: awake, frozen: frozen, empty: empty
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
            VStack(spacing: 4) {
                Text("Nothing said yet")
                    .font(Theme.sans(14, .medium))
                    .foregroundStyle(Theme.text)
                Text(empty)
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.screenDim)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
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
                    LazyVStack(alignment: .leading, spacing: 4) {
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
                    .padding(EdgeInsets(top: 16, leading: 4, bottom: 4, trailing: 4))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.page).shadow(color: .black.opacity(0.5), radius: 4, y: 2))
                    .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .padding(.bottom, 10)
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
    let agentName: String

    var body: some View {
        Text("not heard - \(agentName.lowercased()) was speaking.")
            .font(Theme.mono(12))
            .foregroundStyle(Theme.screenSoft)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { Theme.orange.frame(width: 2) }
            .padding(.vertical, 2)
    }
}

private struct CaptionLine: View {
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
        VStack(alignment: .leading, spacing: 11) {
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
        .padding(.vertical, 5)
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
        FlowLayout(spacing: 8, lineSpacing: 3) {
            Text(speaker)
                .foregroundStyle(line.speaker == .agent ? Theme.orange : Theme.screenDim)
            Text(time).foregroundStyle(Theme.screenDim)
            if let note { Text(note).foregroundStyle(Theme.screenDim) }
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
        .font(Theme.mono(11))
        .spacing(0.04, size: 11)
    }

    private func words(caret: Bool) -> some View {
        let empty = line.text.isEmpty
        let placeholder = switch line.mark {
        case .lost(.stt), .lost(.empty): "Speech could not be transcribed."
        default: "No transcript."
        }
        var words = Text(empty ? placeholder : line.text).foregroundStyle(empty ? Theme.screenDim : ink)
        if case .dropped(.discarded) = line.mark {
            words = words.strikethrough(color: ink.opacity(0.45))
        }
        let text = caret ? Text("\(words)\(Text(Self.caret).baselineOffset(-2.25))") : words
        return text
            .font(Theme.sans(15))
            .lineHeight(.multiple(factor: 1.5))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var ink: Color {
        var color: Color
        if case .lost = line.mark {
            color = Theme.text
        } else if line.unspoken {
            color = Theme.text
        } else if case .dropped = line.mark {
            color = Theme.screenDim
        } else if line.wakeOnly {
            color = Theme.screenDim
        } else {
            color = live ? Theme.text : Theme.screenSoft
        }
        // Interim caller words step back until the transcription's final replaces them.
        if line.speaker == .caller, !line.isFinal, line.mark == nil { color = color.opacity(0.6) }
        return color
    }

    /// A block 0.55em wide and 1em tall, 3pt after the last word.
    private static var caret: Image {
        Image(size: CGSize(width: 11.25, height: 15)) { context in
            context.fill(Path(CGRect(x: 3, y: 0, width: 8.25, height: 15)), with: .color(Theme.orange.opacity(0.9)))
        }
    }

    private func label(_ mark: Transcript.Mark) -> String {
        switch mark {
        case .sending: "sending"
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
        case .sending, .sent: .sent
        case .dropped: .dropped
        case .lost: .lost
        }
    }
}

/// A turn's mark beside the speaker: outlined in its colour, the wake that is still listening filled orange.
private struct MarkTag: View {
    enum Style { case sent, dropped, lost, wake, awake }
    let text: String
    let style: Style

    var body: some View {
        let ink: Color = switch style {
        case .sent: Theme.screenDim
        case .dropped: Theme.screenSoft
        case .lost: Theme.error
        case .wake: Theme.text
        case .awake: Theme.screen
        }
        let boxed = style != .sent
        Text(text)
            .foregroundStyle(ink)
            .lineHeight(.multiple(factor: 1.5))
            .padding(.horizontal, boxed ? 5 : 0)
            .background {
                switch style {
                case .sent: EmptyView()
                case .awake: RoundedRectangle(cornerRadius: 3).fill(Theme.orange)
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
    /// Manual's state, and the words of its open recording.
    var review: Review?
    var draftWords = ""
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

    static func fromEnvironment() -> Preview? {
        #if DEBUG && targetEnvironment(simulator)
            guard var name = ProcessInfo.processInfo.environment["HEYDAN_PREVIEW_PHASE"] else { return nil }
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
            case "failed": (.ended(.failure(.unreachable)), false)
            // Manual: between recordings the microphone is off, as the app keeps it.
            case "manual", "finishing", "draft", "notsent", "toolong": (.live(.listening), true)
            case "recording": (.live(.listening), false)
            case "manual-speaking": (.live(.speaking), true)
            case "kept": (.ended(.init(cause: .remote, message: "The voice service dropped the call.")), false)
            default: nil
            }
            guard let phase else { return nil }
            var preview = Preview(phase: phase.0, muted: phase.muted || mutedVariant)
            if let manual = ManualStage(rawValue: name) { return manualSample(manual, preview: preview) }
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
        /// Manual mode's stages: between turns, a recording, its transcript finishing, a draft (or one that could not
        /// finish, or is too long), a reply over the turn, and a draft kept after the call dropped.
        private enum ManualStage: String {
            case manual, recording, finishing, draft, notsent, toolong, kept
            case speaking = "manual-speaking"
        }

        private static func manualSample(_ stage: ManualStage, preview: Preview) -> Preview {
            var preview = preview
            let start = preview.start
            func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
            var transcript = Transcript()
            let backup = "Can you check whether the backup ran last night?"
            transcript.apply(.status(TurnStatus(turn: 1, status: .sending, text: backup, draft: 1)), at: at(6))
            transcript.apply(.status(TurnStatus(turn: 1, status: .sent, text: backup)), at: at(7))
            transcript.apply(ReplyInfo(reply: 1, turn: 1), at: at(9))
            transcript.caption(segment: "SA_1", text: "It finished at 3:12 with no errors, 41 gigabytes copied.", isFinal: true, fromCaller: false, at: at(9))

            var session = ReviewSession(pick: .review)
            session.startCall()
            var scratch = Transcript()
            var seq = 0
            func state(_ draft: Draft?) {
                seq += 1
                _ = session.receive(ReviewState(seq: seq, mode: .review, draft: draft), transcript: &scratch, micOn: false)
            }
            state(nil)
            let heard = "Add eggs and oat milk to the shopping list, and remind me to call the plumber"
            let draft = "Add eggs and oat milk to the shopping list, and remind me to call the plumber tomorrow at nine."
            switch stage {
            case .manual: break
            case .recording, .finishing:
                _ = session.beginTalk()
                state(Draft(id: 2, state: .recording))
                _ = session.settle(ReviewReply(payload: #"{"gen":1,"ok":true,"seq":\#(seq),"draft":2}"#), agentName: "Dan")
                _ = session.caption(segment: "SR_1", text: heard, knownToTranscript: false)
                if stage == .finishing { state(Draft(id: 2, state: .finishing)) }
            case .draft, .kept: state(Draft(id: 2, state: .ready, text: draft))
            case .speaking: state(Draft(id: 2, state: .ready, text: draft, reason: .agent))
            case .notsent: state(Draft(id: 2, state: .failed, text: heard))
            case .toolong: state(Draft(id: 2, state: .ready, text: String(repeating: draft + " ", count: 90), tooLong: true))
            }
            if stage == .kept {
                session.endCall(byCaller: false)
                preview.wasLive = true
                transcript.end()
            }
            preview.review = session.review
            preview.draftWords = session.words
            preview.transcript = transcript
            if stage != .kept { preview.commands = CommandSettings(picks: .defaults) }
            return preview
        }

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

/// The mascot as a pincer in dots: the notch opens while the call is live.
private enum Claw {
    static let open = [
        ".........", "...##....", "..###....", ".###+....", ".##+++##.",
        ".###+###.", "..#####..", "...###...", ".........",
    ]
    static let closed = [
        ".........", "...###...", "..####...", ".###+.##.", ".##+++##.",
        ".###+###.", "..#####..", "...###...", ".........",
    ]
}

/// The saved voice lines: pick the one the Action Button calls, ask a host who answers, delete, add.
private struct SettingsView: View {
    @Environment(CallController.self) private var call
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var note: Note?
    /// The line whose host is being asked who answers.
    @State private var naming: UUID?
    @State private var deleting: VoiceLines.Entry?

    private enum Note: Equatable {
        case invalid, notSaved, unreadable, asking
        case named(String)
        case unnamed(host: String, reason: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                Text("settings")
                    .font(Theme.sans(17, .medium))
                    .spacing(-0.01, size: 17)
                Button("close") { dismiss() }
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.muted)
                    .frame(minHeight: 44)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    linesSection
                    addSection
                }
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .foregroundStyle(Theme.text)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.card)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .confirmationDialog(
            "Delete the line to \(deleting?.name ?? "")?", isPresented: deletingBinding, titleVisibility: .visible,
            presenting: deleting
        ) { entry in
            Button("Delete", role: .destructive) {
                call.removeLine(entry.id)
                note = nil
            }
        } message: { _ in
            Text("Its call link leaves this phone. Shortcuts that call this line stop working.")
        }
    }

    // MARK: Lines

    private var linesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("voice lines")
            if call.lines.entries.isEmpty {
                Text("no lines yet. add the call link nanoclaw gave you below.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 6) {
                    ForEach(call.lines.entries) { entry in row(entry) }
                }
                Text("the picked line is the one the action button and \"talk to hey dan\" call. a shortcut can call any line by name.")
                    .font(Theme.mono(11))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ entry: VoiceLines.Entry) -> some View {
        let picked = entry.id == call.lines.selected?.id
        return HStack(spacing: 4) {
            Button {
                call.selectLine(entry.id)
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .strokeBorder(picked ? Theme.orange : Theme.outline, lineWidth: 2)
                        .background(Circle().fill(picked ? Theme.orange : .clear).padding(5))
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.agent?.lowercased() ?? "unnamed line")
                            .font(Theme.sans(16, .medium))
                            .foregroundStyle(entry.agent == nil ? Theme.muted : Theme.text)
                        Text(picked ? "\(entry.line.host) · picked" : entry.line.host)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.muted)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name), \(entry.line.host)")
            .accessibilityAddTraits(picked ? .isSelected : [])
            .accessibilityHint(picked ? "" : "Makes this the line the Action Button calls.")
            iconButton("arrow.clockwise", label: "Ask \(entry.line.host) who answers") { ask(entry) }
                .disabled(naming != nil)
                .opacity(naming == entry.id ? 0.4 : 1)
            iconButton("trash", label: "Delete the line to \(entry.name)") { deleting = entry }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(picked ? Theme.orange.opacity(0.07) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(picked ? Theme.orange.opacity(0.55) : Theme.border, lineWidth: 1)
        )
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 15))
            .foregroundStyle(Theme.muted)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: Add

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("add a line")
            HStack(spacing: 10) {
                SecureField(
                    "",
                    text: $link,
                    prompt: Text("https://voice.example.com/voice?t=...").foregroundStyle(Theme.screenDim)
                )
                .font(Theme.mono(14))
                .foregroundStyle(Theme.text)
                .tint(Theme.orange)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(add)
                .padding(.horizontal, 12)
                .frame(height: 46)
                .modifier(InsetWell(radius: 6))
                Button("add", action: add)
                    .buttonStyle(KeyCapStyle(finish: .orange, height: 42))
                    .frame(width: 72)
                    .disabled(link.isEmpty)
            }
            noteText
                .font(Theme.mono(12))
                .lineSpacing(3)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var noteText: some View {
        switch note {
        case .invalid:
            Text("that is not a call link. it looks like https://<host>/voice?t=<token>.").foregroundStyle(Theme.error)
        case .notSaved:
            Text("the keychain did not take the link. try again.").foregroundStyle(Theme.error)
        case .unreadable:
            Text("the saved lines could not be read from the keychain, so nothing is saved over them. restart the phone, then add the link again.")
                .foregroundStyle(Theme.error)
        case .asking:
            Text("asking the host who answers…")
        case let .named(agent):
            Text("\(agent.lowercased()) answers this line.")
        case let .unnamed(host, reason):
            Text("saved, but \(host) did not say who answers: \(reason.lowercased()) the first call names it.")
        case nil:
            Text("paste a voice line link nanoclaw gave you. links stay in the keychain, on this phone only.")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11))
            .spacing(0.06, size: 11)
            .foregroundStyle(Theme.muted)
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func add() {
        guard !link.isEmpty else { return }
        guard VoiceLine(callLink: link) != nil else { return note = .invalid }
        guard let id = call.saveCallLink(link) else { return note = call.linesUnreadable ? .unreadable : .notSaved }
        link = ""
        if let entry = call.lines.entry(id) { ask(entry) }
    }

    private func ask(_ entry: VoiceLines.Entry) {
        naming = entry.id
        note = .asking
        Task {
            do throws(CallFailure) {
                note = .named(try await call.nameLine(entry.id))
            } catch {
                note = .unnamed(host: entry.line.host, reason: error.message)
            }
            naming = nil
        }
    }
}
