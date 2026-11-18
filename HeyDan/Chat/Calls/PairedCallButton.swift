import SwiftUI
import HeyDanCore

struct PairedCallButton: View {
    let target: PairedCallTarget
    let service: any AppService
    let callsEnabled: Bool
    private var call: CallController { .shared }

    var body: some View {
        if callsEnabled {
            Button("Call") {
                if call.pairedCallTarget != nil, call.isCallActive {
                    call.showsPairedCall = true
                    return
                }
                guard !call.isCallActive else { return }
                let callTarget = CallTarget(paired: target, service: service)
                Task {
                    _ = await call.start(target: callTarget)
                }
            }
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
                Button("Close", systemImage: "xmark") { dismiss() }
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.muted)
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
