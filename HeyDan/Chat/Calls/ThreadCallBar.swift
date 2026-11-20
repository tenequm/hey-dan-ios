import SwiftUI
import HeyDanCore

extension CallController.Phase {
    var callBarLabel: String {
        switch self {
        case .idle: ""
        case .connecting: "Connecting..."
        case .joining: "Joining..."
        case .live(.listening): "Listening"
        case .live(.speaking): "Speaking"
        case .live(.thinking): "Thinking"
        case .reconnecting: "Reconnecting"
        case .ended(let ending): ending.message
        }
    }
}

struct ThreadCallBar: View {
    @Environment(\.theme) private var theme
    let target: CallTarget
    private var call: CallController { .shared }
    @State private var presentsCallOptions = false
    @State private var optionsHeight: CGFloat = 240
    @State private var optionsVoice: VoiceSettingsModel?
    @State private var pendingVoice: VoiceTarget?
    @State private var voiceTarget: VoiceTarget?
    @State private var settingsBusy = false

    private struct VoiceTarget: Identifiable {
        let id = UUID()
        let model: VoiceSettingsModel
        let callID: UUID?
    }

    private var displayName: String { call.agentName }
    private var voiceService: (any VoicePickerService)? { call.liveVoiceService ?? target.voicePickerService }
    private var canChangeSettings: Bool {
        if case .live = call.phase { return call.commands != nil }
        return false
    }

    private var releaseWord: String {
        call.commands?.overWords.first.map { "«\($0)»" } ?? "the release word"
    }

    private var activityLabel: String {
        if case .live = call.phase, call.commands?.listenUntilOver == true {
            return "Listening until \(releaseWord)"
        }
        return call.phase.callBarLabel
    }

    private func changeSettings(typing: Bool? = nil, listenUntilOver: Bool? = nil) {
        settingsBusy = true
        Task {
            await call.updateSettings(typing: typing, listenUntilOver: listenUntilOver)
            settingsBusy = false
        }
    }

    var body: some View {
        HStack(spacing: theme.space.s1) {
            GlassIconButton(title: call.isMuted ? "Unmute" : "Mute", systemImage: call.isMuted ? "mic.slash" : "mic") {
                call.setMuted(!call.isMuted)
            }
            .accessibilityIdentifier("controls.mute")
            Spacer(minLength: 0)
            Image(systemName: "waveform").foregroundStyle(theme.color.accent).accessibilityHidden(true)
            Text(activityLabel).textRole(theme.type.label, theme.weight.medium).lineLimit(2)
            CallElapsed(since: call.liveSince)
                .textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
            Spacer(minLength: 0)
            GlassIconButton(title: "Options", systemImage: "ellipsis") { presentsCallOptions = true }
                .accessibilityIdentifier(AXID.controlsOptions)
            Button { call.hangUp() } label: {
                Image(systemName: "phone.down.fill").foregroundStyle(.white)
                    .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
                    .background(theme.color.callEnd, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call")
            .accessibilityIdentifier(AXID.keysCall)
        }
        .padding(theme.space.s1_5)
        .background(theme.color.composer, in: RoundedRectangle(cornerRadius: theme.radius.composer))
        .overlay { RoundedRectangle(cornerRadius: theme.radius.composer).strokeBorder(theme.color.composerBorder).allowsHitTesting(false) }
        .shadow(color: theme.color.shadow, radius: theme.space.s3_5, y: theme.space.s1_5)
        .padding(.horizontal, theme.space.s3)
        .padding(.bottom, theme.space.s1_5)
        .onAppear { call.trace(.call, "thread call bar shown") }
        .sheet(isPresented: $presentsCallOptions, onDismiss: {
            voiceTarget = pendingVoice
            pendingVoice = nil
        }) { callOptions }
        .sheet(item: $voiceTarget) { target in
            VoicePickerSheet(model: target.model, agentName: displayName, callID: target.callID)
        }
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
                        pendingVoice = VoiceTarget(model: picker, callID: call.liveCallID)
                        presentsCallOptions = false
                    } label: {
                        SettingsRow(title: "Voice", icon: "waveform", detail: optionsVoiceName, navigates: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(optionsVoice == nil)
                    .accessibilityIdentifier(AXID.optionsVoice)
                    Divider().overlay(theme.color.border)
                        .padding(.leading, theme.space.s4 + theme.control.glassIcon + theme.space.s3)
                    Toggle(isOn: Binding(get: { call.commands?.typing ?? call.settingsPicks.typing },
                                         set: { changeSettings(typing: $0) })) {
                        SettingsRow(title: "Typing sound", icon: "keyboard", subtitle: "Quiet keys while \(displayName) works on your turn")
                    }
                    .toggleStyle(.switch).tint(theme.color.accent)
                    .padding(.trailing, theme.space.s4)
                    .disabled(settingsBusy || !canChangeSettings)
                    .accessibilityIdentifier(AXID.optionsTyping)
                    if call.commands?.listenUntilOver != nil {
                        Divider().overlay(theme.color.border)
                            .padding(.leading, theme.space.s4 + theme.control.glassIcon + theme.space.s3)
                        Toggle(isOn: Binding(get: { call.commands?.listenUntilOver == true },
                                             set: { changeSettings(listenUntilOver: $0) })) {
                            SettingsRow(title: "Listen until \(releaseWord)", icon: "ear")
                        }
                        .toggleStyle(.switch).tint(theme.color.accent)
                        .padding(.trailing, theme.space.s4)
                        .disabled(settingsBusy || !canChangeSettings)
                        .accessibilityIdentifier("options.listenUntilOver")
                    }
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
}

struct CallElapsed: View {
    let since: Date?

    var body: some View {
        Group {
            if let since { Text(since, style: .timer) } else { Text("0:00") }
        }
        .monospacedDigit().fixedSize()
    }
}
