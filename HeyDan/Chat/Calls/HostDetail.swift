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
            ZStack {
                HStack {
                    GlassIconButton(title: "Back", systemImage: "chevron.left") { dismiss() }
                    Spacer()
                }
                VStack {
                    Text(name).textRole(theme.type.body, theme.weight.bold)
                    Text(connection).textRole(theme.type.label).foregroundStyle(theme.color.textSecondary)
                }
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
                        Toggle(isOn: Binding(get: { active }, set: { selected in
                            guard selected else { return }
                            do { try Pairings.shared.setActive(host: entry.host) }
                            catch { self.error = AppError.map(error).message }
                        })) {
                            SettingsRow(title: "Active host", icon: "star", subtitle: "Open chats on this host")
                        }
                        .padding(.trailing, theme.space.s4).tint(theme.color.accent)
                        .disabled(active)
                    }
                    SettingsSection(footer: "This phone forgets the host's device key. Your chats stay on the host.") {
                        Button { removing = true } label: { SettingsRow(title: "Unpair this host", icon: "trash", destructive: true) }
                            .accessibilityLabel("Unpair")
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
