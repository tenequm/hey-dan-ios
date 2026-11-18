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
    let target: CallTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Its own row: over the call screen's header it would sit on the settings gear and the call clock.
        VStack(spacing: 0) {
            HStack {
                Spacer()
                GlassIconButton(title: "Close", systemImage: "xmark") { dismiss() }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .accessibilityIdentifier("chat.call.close")
            }
            ContentView(pairedTarget: target)
        }
        .background(Theme.page.ignoresSafeArea())
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
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 44, height: 44)
                .glassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    func glassCapsule() -> some View {
        foregroundStyle(Tokens.Color.icon)
            .background(Tokens.Color.glass, in: Capsule())
            .overlay { Capsule().strokeBorder(Tokens.Color.composerBorder) }
            .shadow(color: Tokens.Color.shadow, radius: 8, y: 4)
            .contentShape(Capsule())
    }
}

struct ThreadCallLabel: View {
    var body: some View {
        HStack(spacing: Tokens.Space.s1_5) {
            Image(systemName: "phone").font(.system(size: 17))
            Text("Call").font(.custom("DMSans-Medium", size: 15, relativeTo: .body))
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(minHeight: 44)
        .glassCapsule()
    }
}
