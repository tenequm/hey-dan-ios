import SwiftUI
import HeyDanCore

struct PairedCallButton: View {
    let target: PairedCallTarget
    let service: any AppService
    let callsEnabled: Bool
    private var call: CallController { .shared }

    var body: some View {
        if callsEnabled {
            Button {
                if call.pairedCallTarget != nil, call.isCallActive {
                    call.showsPairedCall = true
                    return
                }
                Task { _ = await call.start(target: CallTarget(paired: target, service: service)) }
            } label: { ThreadCallLabel() }
            .buttonStyle(.plain)
            .disabled(call.isCallActive ? call.pairedCallTarget == nil : !target.conversation.canCall)
            .accessibilityIdentifier("chat.call")
        }
    }
}

struct PairedCallCover: View {
    @Environment(\.theme) private var theme
    let target: CallTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Its own row: over the call screen's header it would sit on the settings gear and the call clock.
        VStack(spacing: 0) {
            HStack {
                Spacer()
                GlassIconButton(title: "Close", systemImage: "xmark") { dismiss() }
                    .padding(.horizontal, theme.space.s5)
                    .padding(.top, theme.space.s2)
                    .accessibilityIdentifier("chat.call.close")
            }
            ContentView(pairedTarget: target)
        }
        .background(theme.color.surface.ignoresSafeArea())
        .onAppear {
            if let paired = target.paired, ChatController.shared.host == paired.host {
                ChatController.shared.openConversation(paired.conversation.id)
            }
        }
    }
}

struct ThreadCallButton: View {
    let conversation: Conversation
    private var chat: ChatController { .shared }
    @State private var showsSettings = false
    var body: some View {
        Button("Settings", systemImage: "gearshape") { showsSettings = true }
            .sheet(isPresented: $showsSettings) {
                NavigationStack {
                    Form { PairedSettingsSection() }
                        .navigationTitle("Settings")
                        .toolbar { Button("Done") { showsSettings = false } }
                }
            }
        if let host = chat.host, let pairing = chat.pairing {
            PairedCallButton(target: PairedCallTarget(host: host, deviceId: pairing.deviceId,
                conversation: chat.conversations.first { $0.id == conversation.id } ?? conversation),
                service: chat.service, callsEnabled: chat.features.contains("calls"))
        }
    }
}

struct GlassIconButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: theme.control.glassIcon, weight: theme.weight.medium, design: theme.type.familySystem))
                .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
                .glassCapsule(theme)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    func glassCapsule(_ theme: Tokens) -> some View {
        foregroundStyle(theme.color.icon)
            .background(theme.color.glass, in: Capsule())
            .overlay { Capsule().strokeBorder(theme.color.composerBorder) }
            .shadow(color: theme.color.shadow, radius: theme.space.s2, y: theme.space.s1)
            .contentShape(Capsule())
    }
}

struct ThreadCallLabel: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: theme.space.s1_5) {
            Image(systemName: "phone").font(.system(size: theme.control.phoneIcon, design: theme.type.familySystem))
            Text("Call").font(.custom(theme.type.face(theme.weight.medium), size: theme.control.callLabel, relativeTo: .body))
        }
        .padding(.leading, theme.space.s3_5)
        .padding(.trailing, theme.space.s4)
        .frame(minHeight: theme.control.touchTarget)
        .glassCapsule(theme)
    }
}
