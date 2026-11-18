import HeyDanCore
import SwiftUI

struct HostDetail: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let entry: Pairings.Entry
    @State private var removing = false
    @State private var error: String?
    private var name: String { entry.host.host() ?? "Host" }
    private var active: Bool { Pairings.shared.active?.host == entry.host }
    private var connection: String {
        guard active else { return "Inactive" }
        switch ChatController.shared.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: theme.space.s3) {
                GlassIconButton(title: "Back", systemImage: "chevron.left") { dismiss() }
                VStack(alignment: .leading) {
                    Text(name).textRole(theme.type.body, theme.weight.bold)
                    Text(connection).textRole(theme.type.label).foregroundStyle(theme.color.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, theme.space.s4).padding(.vertical, theme.space.s1_5)
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    SettingsSection("Connection") {
                        SettingsRow(title: "Status", icon: "wifi", detail: connection)
                        SettingsRow(title: "Address", icon: "globe", detail: entry.host.absoluteString)
                        SettingsRow(title: "Paired as", icon: "iphone", detail: entry.userName)
                    }
                    let voices = entry.features.contains("voice-picker")
                    SettingsSection("Agents", footer: voices ? "Tap an agent to change its voice." : nil) {
                        ForEach(entry.agents, id: \.id) { agent in
                            if voices { AgentVoiceRow(agent: agent, entry: entry) }
                            else { SettingsRow(title: agent.name, icon: "person") }
                        }
                    }
                    SettingsSection {
                        Button {
                            do { try Pairings.shared.setActive(host: entry.host) }
                            catch { self.error = AppError.map(error).message }
                        } label: {
                            SettingsRow(title: active ? "Active host" : "Select host", icon: "star",
                                        detail: active ? "Selected" : nil)
                        }
                        .disabled(active)
                    }
                    SettingsSection(footer: "This phone forgets the host's device key. Your chats stay on the host.") {
                        Button { removing = true } label: { SettingsRow(title: "Unpair", icon: "link.badge.minus", destructive: true) }
                    }
                    if let error { Text(error).textRole(theme.type.footnote).foregroundStyle(theme.color.danger) }
                }
                .padding(theme.space.s4)
            }
        }
        .buttonStyle(.plain).foregroundStyle(theme.color.textPrimary)
        .background(theme.color.surface.ignoresSafeArea()).toolbarVisibility(.hidden, for: .navigationBar)
        .sheet(isPresented: $removing) {
            UnpairSheet(entry: entry) { failure in
                removing = false
                if let failure { error = failure } else { dismiss() }
            }
        }
    }
}
