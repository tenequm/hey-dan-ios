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
                PairedCallCover(conversationId: target.conversation.id)
            }
        }
    }
}

private struct PairedCallCover: View {
    let conversationId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentView()
            .overlay(alignment: .topTrailing) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .padding()
                    .accessibilityIdentifier("chat.call.close")
            }
            .onAppear { ChatController.shared.openConversation(conversationId) }
    }
}
