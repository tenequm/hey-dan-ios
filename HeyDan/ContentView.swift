import HeyDanCore
import SwiftUI

struct ContentView: View {
    @Environment(\.theme) private var theme
    var pairedTarget: CallTarget?
    var minimize: (() -> Void)?
    @Environment(CallController.self) private var call
    @State private var showsSettings = false
    @State private var presentsCallOptions = false
    @State private var optionsHeight: CGFloat = 240
    @State private var optionsVoice: VoiceSettingsModel?
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
        let model: VoiceSettingsModel
        let agentName: String
        let callID: UUID?
    }

    var body: some View {
        VStack(spacing: theme.space.s4) {
            header
            screen
            controls
            if let rv = reviewKeys {
                HStack(spacing: theme.space.s3_5) { reviewKeyPair(rv) }
            }
        }
        .padding(.horizontal, theme.space.s4)
        .padding(.bottom, theme.space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.color.surface.ignoresSafeArea())
        .foregroundStyle(theme.color.textPrimary)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sheet(isPresented: $showsSettings) {
            if Pairings.shared.active == nil {
                VoiceLinesSettings()
            } else {
                NavigationStack { PairedSettingsSection(close: { showsSettings = false }) }
            }
        }
        .sheet(isPresented: $presentsCallOptions, onDismiss: {
            guard let target = pendingVoiceTarget else { return }
            pendingVoiceTarget = nil
            voiceTarget = target
        }) { callOptions }
        .sheet(item: $voiceTarget) { target in
            VoicePickerSheet(model: target.model, agentName: target.agentName, callID: target.callID)
        }
        // Only once the pairings are read: a paired phone with no saved line shows the conversation list, not Settings.
        .onChange(of: Pairings.shared.state, initial: true) { _, state in
            if state == .none, preview == nil, pairedTarget == nil, call.line == nil, !call.isCallActive {
                showsSettings = true
            }
        }
        .onAppear {
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
        ZStack {
            VStack(spacing: 0) {
                Text(displayName).textRole(theme.type.headline, theme.weight.semibold)
                HStack(spacing: theme.space.s1) {
                    if let host = pairedTarget?.paired?.host.host() { Text(host) }
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

    private var displayName: String { pairedTarget?.paired?.conversation.agent.name ?? call.agentName }

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
                empty: panel == nil && !hintIsError ? emptyDescription : nil
            )
        }
        .padding(.horizontal, theme.space.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        CallStateChip(label: reviewReadout.map { asWritten($0.chip, keep: keepWords) } ?? chipText,
                      dot: chipColor)
    }

    private var chipColor: Color {
        if hintIsError || reviewReadout?.tone == .error { return theme.color.danger }
        if phase == .connecting || phase == .reconnecting { return theme.color.warning }
        if isMuted { return theme.color.iconMuted }
        if phase == .live(.speaking) { return theme.color.accent }
        if isLive { return phase == .live(.thinking) ? theme.color.statusWorking : theme.color.statusConnected }
        return theme.color.iconMuted
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
            if hintIsError && reviewKeys == nil {
                HStack(spacing: theme.space.s3) {
                    optionsControl.fixedSize()
                    Button { Task { await startDisplayedCall() } } label: {
                        Text("Call again").textRole(theme.type.body, theme.weight.medium)
                            .frame(maxWidth: .infinity, minHeight: theme.control.touchTarget)
                            .background(theme.color.accent, in: Capsule())
                            .foregroundStyle(theme.color.onAccent)
                    }
                    .accessibilityIdentifier(AXID.keysCall)
                    .disabled(!hasLine)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { controlButtons }
                    ScrollView(.horizontal) { HStack { controlButtons } }
                }
            }
            if reviewKeys?.panel == nil, let note = review.note {
                Text(asWritten(note, keep: keepWords)).textRole(theme.type.caption)
                    .foregroundStyle(theme.color.textSecondary)
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
        if reviewKeys == nil {
            Button { call.setMuted(!isMuted) } label: {
                CallControlLabel(title: isMuted ? "Unmute" : "Mute", symbol: isMuted ? "mic.slash" : "mic")
            }
            .disabled(!isCallActive || switchingToReview)
            .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
            .accessibilityValue(micLabel)
        }
        modeControl
        optionsControl

        if reviewKeys == nil {
            Button {
                if isCallActive { call.hangUp() } else { Task { await startDisplayedCall() } }
            } label: {
                CallControlLabel(title: callKey.title.capitalized, symbol: isCallActive ? "phone.down.fill" : "phone.fill",
                                 danger: isCallActive)
            }
            .accessibilityIdentifier(AXID.keysCall)
            .accessibilityLabel(callKey.spoken)
            .disabled((!isCallActive && !hasLine) || (isSettingUp && !cancelArmed))
        }
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

    private var modeControl: some View {
        Menu {
            Picker("Turn mode", selection: Binding(
                get: { review.mode },
                set: { mode in Task { await call.setTurnMode(mode) } }
            )) {
                ForEach([TurnMode.auto, .review], id: \.self) { mode in
                    LabeledContent {
                        Text(modeCaption(mode)).lineLimit(1)
                    } label: {
                        Text(modeTitle(mode))
                    }
                    .tag(mode)
                    .disabled(mode == .review && !review.available && review.mode != .review)
                }
            }
        } label: {
            CallControlLabel(title: modeLabel, symbol: "hand.raised")
        }
        .disabled(modeDisabled)
        .accessibilityIdentifier(AXID.controlsMode)
        .accessibilityLabel("Turn mode")
        .accessibilityValue(modeLabel)
        .accessibilityHint(modeCaption(pendingMode ?? review.mode))
    }

    private var pendingMode: TurnMode? { review.pending?.op == .mode ? review.pending?.to : nil }

    private var modeLabel: String {
        pendingMode == nil ? modeTitle(review.mode) : "Switching..."
    }

    /// The control row capitalizes hands-free, which `Review.modeName` writes lowercase.
    private func modeTitle(_ mode: TurnMode) -> String { mode == .auto ? "Hands-free" : Review.modeName(mode) }

    /// A redial starts from the conversation as the list has it now; the host still decides whether it may call.
    private func startDisplayedCall() async {
        if let target = pairedTarget, let paired = target.paired, let service = target.service {
            let chat = ChatController.shared
            let live = chat.host == paired.host ? chat.conversations.first { $0.id == paired.conversation.id } : nil
            _ = await call.start(target: CallTarget(paired: PairedCallTarget(host: paired.host, deviceId: paired.deviceId,
                conversation: live ?? paired.conversation), service: service))
        } else { _ = await call.start(lineID: call.shownLineID) }
    }

    private var voiceService: (any VoicePickerService)? {
        if let service = call.liveVoiceService { return service }
        if let pairedTarget { return pairedTarget.voicePickerService }
        return (call.shownLineID.flatMap(call.lines.entry)?.line ?? call.line).map(VoiceSettingsModel.lineService)
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
                        pendingVoiceTarget = VoiceTarget(model: picker, agentName: displayName, callID: call.liveCallID)
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

    // MARK: Keys

    /// Review relabels the same two caps: discard is the quiet choice next to send, every other left key keeps the accent.
    @ViewBuilder private func reviewKeyPair(_ rv: ReviewView) -> some View {
        let primaryDisabled = (!isCallActive && !hasLine) || (isSettingUp && !cancelArmed)
        let leftArmed = (leftArmedAs ?? leftIdentity) == leftIdentity
        let rightArmed = (rightArmedAs ?? rightIdentity) == rightIdentity
        VStack(spacing: theme.space.s1_5) {
            Button(asWritten(rv.left.label, keep: [])) { run(rv.left.action) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .tint(rv.left.action == .discard ? theme.color.secondaryFill : theme.color.accent)
                .accessibilityIdentifier(AXID.keysCall)
                .disabled(rv.left.disabled || !leftArmed || ((rv.left.action == .call || rv.left.action == .cancel) && primaryDisabled))
            keyLabel(Text(review.ended && review.draft != nil ? "draft kept" : callLabel))
        }
        VStack(spacing: theme.space.s1_5) {
            Button {
                run(rv.right.action)
            } label: {
                HStack(spacing: theme.space.s1_5) {
                    Image(systemName: rv.right.action == .done ? "stop.fill" : rv.right.action == .send ? "arrow.up" : "mic.fill")
                        .font(.system(size: rv.right.action == .done ? theme.type.caption.size : theme.type.body.size, weight: theme.weight.semibold))
                    Text(asWritten(rv.right.label, keep: []))
                }
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .tint(rv.right.action == .send && !rv.right.disabled ? theme.color.accent : theme.color.surfaceGrouped)
            .disabled(rv.right.disabled || !rightArmed)
            keyLabel(HStack(spacing: theme.space.s1_5) {
                Circle().fill(rv.capturing || review.micError == .stop ? theme.color.statusConnected : theme.color.iconMuted)
                    .frame(width: theme.space.s2, height: theme.space.s2)
                Text(asWritten(rv.mic, keep: []))
            })
        }
        .frame(width: min(muteWidth, 180))
    }

    private func run(_ action: ReviewView.Action) {
        switch action {
        case .call: Task { await startDisplayedCall() }
        case .cancel, .end: call.hangUp()
        case .discard: Task { await call.discard() }
        case .talk: Task { await call.talk() }
        case .done: Task { await call.done() }
        case .send: Task { await call.send() }
        }
    }

    private func keyLabel(_ content: some View) -> some View {
        content
            .textRole(theme.type.micro)
            .spacing(0.06, size: 11)
            .foregroundStyle(theme.color.textSecondary)
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
    private var hasLine: Bool { pairedTarget != nil || call.line != nil || preview != nil }
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

private struct DraftPanel: View {
    @Environment(\.theme) private var theme
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
            FlowLayout(spacing: theme.space.s2_5, lineSpacing: theme.space.s0_5) {
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
            .textRole(theme.type.micro)
            .spacing(0.04, size: 11)
            .foregroundStyle(theme.color.textSecondary)
            .padding(EdgeInsets(top: theme.space.s2, leading: theme.space.s3, bottom: theme.space.s1, trailing: theme.space.s3))
            if let note {
                Text(asWritten(note, keep: keep))
                    .textRole(theme.type.micro)
                    .foregroundStyle(theme.color.accentText)
                    .padding(EdgeInsets(top: 0, leading: theme.space.s3, bottom: theme.space.s1, trailing: theme.space.s3))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Group {
                    if text.isEmpty {
                        Text(panel.tone == .hearing ? "Speak now…" : panel.tone == .finishing ? "…" : "No words.")
                            .foregroundStyle(theme.color.textSecondary)
                    } else {
                        Text(text)
                            .foregroundStyle(hearing ? theme.color.textSecondary : theme.color.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .textRole(theme.type.headline)
                .lineHeight(.multiple(factor: 1.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 0, leading: theme.space.s3, bottom: theme.space.s2_5, trailing: theme.space.s3))
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
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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
        case .draft: theme.color.accentText
        case .failed, .long, .empty: theme.color.danger
        case .hearing, .finishing: theme.color.textPrimary
        }
    }
}

private struct PanelButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s1_5) {
                Image(systemName: systemImage).font(.system(size: theme.type.micro.size))
                Text(title)
            }
            .foregroundStyle(theme.color.textPrimary)
            .padding(.horizontal, theme.space.s2)
            .padding(.vertical, theme.space.s0_5)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.color.textPrimary, lineWidth: 1))
            .padding(.vertical, theme.space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The delivery notice and the transcript: the only views that read the call's transcript, so a caption re-runs
/// them and not the whole screen.
private struct TranscriptPane: View {
    @Environment(\.theme) private var theme
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
struct VoiceLinesSettings: View {
    @Environment(\.theme) private var theme
    @Environment(CallController.self) private var call
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @FocusState private var linkFocused: Bool
    @State private var note: Note?
    /// The line whose host is being asked who answers.
    @State private var naming: UUID?
    @State private var deleting: VoiceLines.Entry?
    @State private var voiceLine: VoiceLines.Entry?

    private enum Note: Equatable {
        case invalid, notSaved, unreadable, asking
        case named(String)
        case unnamed(host: String, reason: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            ZStack {
                Text("Voice lines")
                    .textRole(theme.type.headline, theme.weight.medium)
                    .spacing(-0.01, size: 17)
                HStack {
                    GlassIconButton(title: "close", systemImage: "chevron.left") { dismiss() }
                    Spacer()
                    if Pairings.shared.active == nil {
                        GlassIconButton(title: "Add a call link", systemImage: "plus") { linkFocused = true }
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    if Pairings.shared.active != nil { PairedSettingsSection() }
                    linesSection
                    addSection
                    if Pairings.shared.active == nil { PairedSettingsSection() }
                }
                .padding(.bottom, theme.space.s5)
            }
            .scrollBounceBehavior(.basedOnSize)
            if Pairings.shared.active == nil, let selected = call.lines.selected {
                Button {
                    dismiss()
                    Task { _ = await call.start(lineID: selected.id) }
                } label: {
                    Label("Call \(selected.name)", systemImage: "phone.fill")
                        .textRole(theme.type.body, theme.weight.semibold)
                        .frame(maxWidth: .infinity, minHeight: theme.control.touchTarget)
                        .background(theme.color.accent, in: Capsule())
                        .foregroundStyle(theme.color.onAccent)
                }
                .disabled(call.isCallActive)
                .padding(.bottom, theme.space.s2)
            }
        }
        .padding(.horizontal, theme.space.s5)
        .padding(.top, theme.space.s3)
        .foregroundStyle(theme.color.textPrimary)
        .presentationDetents(Pairings.shared.active == nil ? [.large] : [.medium, .large])
        .presentationBackground(theme.color.surfaceSheet)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .confirmationDialog(
            "Delete the line to \(deleting?.name ?? "")?", item: $deleting, titleVisibility: .visible
        ) { entry in
            Button("Delete", role: .destructive) {
                call.removeLine(entry.id)
                note = nil
            }
        } message: { _ in
            Text("Its call link leaves this phone. Shortcuts that call this line stop working.")
        }
        .sheet(item: $voiceLine) { entry in
            VoicePickerSheet(service: VoiceSettingsModel.lineService(entry.line), agentName: entry.name, callID: nil)
        }
    }

    // MARK: Lines

    private var linesSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            label("Saved lines")
            if call.lines.entries.isEmpty {
                Text("no lines yet. add the call link nanoclaw gave you below.")
                    .textRole(theme.type.caption)
                    .foregroundStyle(theme.color.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(call.lines.entries) { entry in row(entry) }
                }
                .background(theme.color.surfaceGrouped, in: RoundedRectangle(cornerRadius: theme.radius.l))
                Text("the picked line is the one the action button and \"talk to hey dan\" call. a shortcut can call any line by name.")
                    .textRole(theme.type.micro)
                    .lineSpacing(theme.space.s1)
                    .foregroundStyle(theme.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ entry: VoiceLines.Entry) -> some View {
        let picked = entry.id == call.lines.selected?.id
        return HStack(spacing: theme.space.s1) {
            Button {
                call.selectLine(entry.id)
            } label: {
                HStack(spacing: theme.space.s3) {
                    VStack(alignment: .leading, spacing: theme.space.s0_5) {
                        Text(entry.agent ?? "Unnamed line")
                            .textRole(theme.type.body, theme.weight.medium)
                            .foregroundStyle(entry.agent == nil ? theme.color.textSecondary : theme.color.textPrimary)
                        Text(entry.line.host)
                            .textRole(theme.type.micro)
                            .foregroundStyle(theme.color.textSecondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    if picked {
                        Image(systemName: "checkmark").foregroundStyle(theme.color.accentText)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: theme.control.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.name), \(entry.line.host)")
            .accessibilityAddTraits(picked ? .isSelected : [])
            .accessibilityHint(picked ? "" : "Makes this the line the Action Button calls.")
            Menu {
                Button("Voice...", systemImage: "waveform") { voiceLine = entry }
                Button("Ask who answers", systemImage: "arrow.clockwise") { ask(entry) }
                    .disabled(naming != nil)
                Button("Delete...", systemImage: "trash", role: .destructive) { deleting = entry }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: theme.type.body.size))
                    .foregroundStyle(theme.color.textSecondary.opacity(naming == entry.id ? 0.4 : 1))
                    .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(entry.name)")
        }
        .padding(.leading, theme.space.s3)
        .padding(.trailing, theme.space.s0_5)
        .padding(.vertical, theme.space.s1)
    }

    // MARK: Add

    private var addSection: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            label("Add a call link")
            HStack(spacing: theme.space.s2_5) {
                SecureField(
                    "",
                    text: $link,
                    prompt: Text("https://voice.example.com/voice?t=...").foregroundStyle(theme.color.placeholder)
                )
                .textRole(theme.type.footnote)
                .foregroundStyle(theme.color.textPrimary)
                .tint(theme.color.accentText)
                .textContentType(.URL)
                .focused($linkFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(add)
                .padding(.horizontal, theme.space.s3)
                .frame(height: 46)
                .background(theme.color.surfaceInput, in: RoundedRectangle(cornerRadius: theme.radius.field))
                Button("add", action: add)
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(theme.color.accent)
                    .frame(width: 72)
                    .disabled(link.isEmpty)
            }
            noteText
                .textRole(theme.type.caption)
                .lineSpacing(theme.space.s1)
                .foregroundStyle(theme.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var noteText: some View {
        switch note {
        case .invalid:
            Text("that is not a call link. it looks like https://<host>/voice?t=<token>.").foregroundStyle(theme.color.danger)
        case .notSaved:
            Text("the keychain did not take the link. try again.").foregroundStyle(theme.color.danger)
        case .unreadable:
            Text("the saved lines could not be read from the keychain, so nothing is saved over them. restart the phone, then add the link again.")
                .foregroundStyle(theme.color.danger)
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
            .textRole(theme.type.micro)
            .spacing(0.06, size: 11)
            .foregroundStyle(theme.color.textSecondary)
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
