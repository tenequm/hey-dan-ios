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
    @State private var expiredCaptionDeadline: Date?
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
    private var canChangeTyping: Bool {
        if case .live = call.phase { return call.commands != nil }
        return false
    }

    var body: some View {
        VStack(spacing: theme.space.s1) {
            if case let .live(activity) = call.phase, activity != .speaking, !call.isMuted,
               let caption = call.transcript.latestCallerCaption,
               caption.captionDeadline.map({ $0 > .now && $0 != expiredCaptionDeadline }) ?? true {
                Text(verbatim: caption.text)
                    .textRole(theme.type.label)
                    .foregroundStyle(caption.isFinal ? theme.color.textPrimary : theme.color.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .accessibilityIdentifier("call.callerCaption")
                    .task(id: caption.captionDeadline) {
                        guard let deadline = caption.captionDeadline else { return }
                        do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
                        catch { return }
                        expiredCaptionDeadline = deadline
                    }
            }
            controls
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

    private var controls: some View {
        HStack(spacing: theme.space.s1) {
            GlassIconButton(title: call.isMuted ? "Unmute" : "Mute", systemImage: call.isMuted ? "mic.slash" : "mic") {
                call.setMuted(!call.isMuted)
            }
            .accessibilityIdentifier("controls.mute")
            Spacer(minLength: 0)
            Image(systemName: "waveform").foregroundStyle(theme.color.accent).accessibilityHidden(true)
            Text(call.phase.callBarLabel).textRole(theme.type.label, theme.weight.medium).lineLimit(1)
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
                    Toggle(isOn: Binding(get: { call.commands?.typing ?? call.settingsPicks.typing }, set: { typing in
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
