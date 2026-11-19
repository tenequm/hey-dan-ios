import HeyDanCore
import SwiftUI
import UserNotifications

struct PairedSettingsSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scene
    @Environment(\.openURL) private var openURL
    @State private var notifications = false
    var close: (() -> Void)?
    private var pairings: Pairings { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").textRole(theme.type.title, theme.weight.bold)
                Spacer()
                if let close { GlassIconButton(title: "Done", systemImage: "xmark", action: close) }
            }
            .padding(.horizontal, theme.space.s5).frame(minHeight: theme.control.touchTarget + theme.space.s3)
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    PairedHostSettingsRows()
                    if pairings.entries.contains(where: { $0.features.contains("push") }) {
                        SettingsSection("Notifications") {
                            Toggle(isOn: Binding(get: { notifications }, set: { _ in
                                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                            })) {
                                SettingsRow(title: "Message notifications", icon: "bell",
                                            subtitle: "Show replies and questions on the lock screen")
                            }
                            .padding(.trailing, theme.space.s4).tint(theme.color.accent)
                        }
                    }
                    let hosts = pairings.entries.filter { $0.features.contains("voice-picker") && !$0.agents.isEmpty }
                    if !hosts.isEmpty {
                        SettingsSection("Voices", footer: "Voices are saved on each host and apply to every paired phone.") {
                            ForEach(hosts, id: \.host) { entry in
                                ForEach(entry.agents, id: \.id) { agent in
                                    AgentVoiceRow(agent: agent, entry: entry)
                                }
                            }
                        }
                    }
                }
                .padding(theme.space.s4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.settings.pairings")
        .foregroundStyle(theme.color.textPrimary)
        .background(theme.color.surface.ignoresSafeArea())
        .toolbarVisibility(.hidden, for: .navigationBar)
        .task(id: scene) {
            if scene == .active {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notifications = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            }
        }
    }
}

struct PairedHostSettingsRows: View {
    @State private var showsPairing = false

    var body: some View {
        SettingsSection("Paired hosts") {
            ForEach(Pairings.shared.entries, id: \.host) { entry in
                NavigationLink { HostDetail(entry: entry) } label: { PairedHostRow(entry: entry) }
                    .accessibilityIdentifier("chat.settings.host.\(entry.host.host() ?? "")")
            }
            Button { showsPairing = true } label: { SettingsRow(title: "Pair a host", icon: "plus") }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsPairing) { PairingView() }
    }
}

private struct PairedHostRow: View {
    @Environment(\.theme) private var theme
    let entry: Pairings.Entry

    var body: some View {
        let active = Pairings.shared.active?.host == entry.host
        HStack(spacing: theme.space.s3) {
            Circle().fill(active && ChatController.shared.connectionState == .connected
                          ? theme.color.statusConnected : theme.color.iconMuted)
                .frame(width: theme.space.s2, height: theme.space.s2)
            VStack(alignment: .leading, spacing: theme.space.s0_5) {
                HStack(spacing: theme.space.s1_5) {
                    Text(entry.host.host() ?? "Host").textRole(theme.type.body, theme.weight.bold)
                    if active {
                        Text("Active").textRole(theme.type.micro, theme.weight.bold)
                            .padding(.horizontal, theme.space.s2)
                            .foregroundStyle(theme.color.accentText).background(theme.color.accentSoft, in: Capsule())
                    }
                }
                Text(([entry.userName] + entry.agents.map(\.name)).joined(separator: " · "))
                    .textRole(theme.type.label).foregroundStyle(theme.color.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(theme.color.chevron)
        }
        .padding(.horizontal, theme.space.s4).padding(.vertical, theme.space.s3_5).contentShape(Rectangle())
    }
}

struct AgentVoiceRow: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let entry: Pairings.Entry
    @State private var selection: PairedVoicePickerService?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Button {
            loading = true
            Task {
                defer { loading = false }
                do {
                    let found = try await ChatController.shared.pairedConversation(agentId: agent.id, entry: entry)
                    guard let conversation = found.conversation else { error = "This agent has no conversation yet."; return }
                    selection = PairedVoicePickerService(target: PairedCallTarget(host: entry.host, deviceId: entry.deviceId,
                        conversation: conversation), service: found.service)
                } catch { self.error = AppError.map(error).message }
            }
        } label: {
            SettingsRow(title: agent.name, icon: "waveform", navigates: true)
        }
        .disabled(loading).accessibilityLabel("Voice: \(agent.name)")
        .sheet(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let selection { VoicePickerSheet(service: selection, agentName: agent.name, callID: nil) }
        }
        .alert("Voice", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}
