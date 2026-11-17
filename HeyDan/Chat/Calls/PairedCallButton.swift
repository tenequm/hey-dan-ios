import SwiftUI
import HeyDanCore

struct PairedCallButton: View {
    let target: PairedCallTarget
    let service: any AppService
    let callsEnabled: Bool
    @State private var showsCall = false

    var body: some View {
        if callsEnabled {
            VStack {
                Button("Call") {
                    guard !CallController.shared.isCallActive else { return }
                    let callTarget = CallTarget(paired: target, service: service)
                    Task {
                        if await CallController.shared.start(target: callTarget) != nil { showsCall = true }
                    }
                }
                .disabled(!target.conversation.canCall || CallController.shared.isCallActive)
                .accessibilityIdentifier("chat.call")
                if !target.conversation.canCall, let refusal = target.conversation.callRefusal {
                    Text(refusal.message)
                        .accessibilityIdentifier("chat.call.refusal")
                }
            }
            .fullScreenCover(isPresented: $showsCall) {
                PairedCallCover(target: CallTarget(paired: target, service: service))
            }
        }
    }
}

private struct PairedCallCover: View {
    let target: CallTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentView(pairedTarget: target)
            .overlay(alignment: .topTrailing) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .padding()
                    .accessibilityIdentifier("chat.call.close")
            }
            .onAppear { if let paired = target.paired { ChatController.shared.openConversation(paired.conversation.id) } }
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
