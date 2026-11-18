import SwiftUI
import HeyDanCore

struct PairedSettingsSection: View {
    @State private var showsPairing = false
    @State private var removing: URL?
    @State private var voice: Selection?
    @State private var error: String?
    private var pairings: Pairings { .shared }
    private struct Selection: Identifiable {
        let id = UUID()
        let service: PairedVoicePickerService
        let name: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paired hosts").font(.headline)
            ForEach(pairings.entries, id: \.host) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.host.host() ?? "Host")
                    Text(entry.userName)
                    Button(pairings.active?.host == entry.host ? "Selected" : "Select host") {
                        do { try pairings.setActive(host: entry.host) }
                        catch { self.error = AppError.map(error).message }
                    }
                    .disabled(pairings.active?.host == entry.host)
                    ForEach(entry.agents, id: \.id) { agent in
                        if entry.features.contains("voice-picker") {
                            Button("Voice: \(agent.name)") {
                                Task {
                                    let chat = ChatController.shared
                                    guard let conversation = await chat.conversation(forAgent: agent.id, host: entry.host),
                                          chat.host == entry.host, chat.pairing?.deviceId == entry.deviceId else {
                                        error = chat.error?.message ?? "This agent has no conversation yet."
                                        return
                                    }
                                    voice = Selection(service: PairedVoicePickerService(target:
                                        PairedCallTarget(host: entry.host, deviceId: entry.deviceId, conversation: conversation),
                                        service: chat.service), name: agent.name)
                                }
                            }
                        } else { Text(agent.name) }
                    }
                    Button("Unpair", role: .destructive) { removing = entry.host }
                }
            }
            Button("Pair a host") { showsPairing = true }
            if let error { Text(error) }
            if let error = ChatController.shared.error { Text(error.message) }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("chat.settings.pairings")
        .sheet(isPresented: $showsPairing) { PairingView() }
        .sheet(item: $voice) { selection in
            VoicePickerSheet(service: selection.service, agentName: selection.name, callID: nil)
        }
        .confirmationDialog("Unpair this host?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                if let host = removing { Task { await ChatController.shared.unpair(host: host) } }
                removing = nil
            }
        }
    }
}
