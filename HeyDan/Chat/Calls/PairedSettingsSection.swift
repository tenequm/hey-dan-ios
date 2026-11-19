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
    @AppStorage("defaultCallAgent") private var defaultAgent = ""

    private var callAgents: [AgentEntity] {
        pairings.entries.filter { $0.features.contains("calls") }.flatMap { entry in
            entry.agents.map { AgentEntity(entry: entry, agent: $0) }
        }
    }
    private var defaultName: String {
        defaultAgent.isEmpty ? "First on active host" : callAgents.first { $0.id.uuidString == defaultAgent }?.agent ?? "Unavailable"
    }

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
                    let agentHosts = pairings.entries.filter { $0.features.contains("agents") }
                    if !agentHosts.isEmpty {
                        SettingsSection {
                            NavigationLink {
                                AgentSettings()
                            } label: {
                                SettingsRow(title: "Agents", icon: "person.2", navigates: true)
                            }
                        }
                    }
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
                    SettingsSection("Calls") {
                        Menu {
                            Picker("Default agent", selection: $defaultAgent) {
                                Text("First agent on active host").tag("")
                                ForEach(callAgents, id: \.id) { agent in
                                    Text("\(agent.agent) · \(agent.source)").tag(agent.id.uuidString)
                                }
                            }
                        } label: {
                            SettingsRow(title: "Default agent", icon: "phone", detail: defaultName, navigates: true)
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

private struct AgentSettings: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    GlassIconButton(title: "Back", systemImage: "chevron.left") { dismiss() }
                        .accessibilityIdentifier("chat.settings.agents.back")
                    Spacer()
                }
                Text("Agents").textRole(theme.type.body, theme.weight.bold).accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, theme.space.s4).padding(.vertical, theme.space.s1_5)
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    ForEach(Pairings.shared.entries.filter { $0.features.contains("agents") }, id: \.host) { entry in
                        HostAgentToggles(entry: entry).id(entry.deviceId)
                    }
                }
                .padding(theme.space.s4)
            }
        }
        .foregroundStyle(theme.color.textPrimary)
        .background(theme.color.surface.ignoresSafeArea()).toolbarVisibility(.hidden, for: .navigationBar)
    }
}

private struct HostAgentToggles: View {
    @Environment(\.theme) private var theme
    let entry: Pairings.Entry
    @State private var candidates: [AgentCandidate]?
    @State private var pending: [String: Bool] = [:]
    @State private var error: String?
    @State private var revision = 0
    private var chat: ChatController { .shared }

    var body: some View {
        SettingsSection(entry.host.host() ?? "Host") {
            if let candidates {
                let duplicates = Dictionary(grouping: candidates, by: \.name)
                ForEach(candidates) { agent in
                    Toggle(isOn: Binding(get: { pending[agent.id] ?? agent.shown }, set: { update(agent, shown: $0) })) {
                        SettingsRow(title: agent.name, icon: "person",
                            subtitle: duplicates[agent.name, default: []].count > 1 ? agent.chat : nil)
                    }
                    .padding(.trailing, theme.space.s4)
                    .disabled(pending[agent.id] != nil)
                    .tint(theme.color.accent)
                    .accessibilityIdentifier("chat.settings.agent.\(agent.id)")
                }
                if candidates.isEmpty { Text("No agents available") }
            } else if error == nil {
                ProgressView()
            } else {
                Button("Retry") { Task { await load() } }
            }
            if let error { Text(error).foregroundStyle(theme.color.danger) }
        }
        .task(id: chat.host == entry.host ? Set(chat.conversations.map { $0.agent.id }) : []) { await load() }
    }

    private func load() async {
        let started = revision
        do {
            let result = try await chat.service(for: entry).agents()
            guard !Task.isCancelled, started == revision else { return }
            candidates = result.agents
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.message }
        }
    }

    private func update(_ agent: AgentCandidate, shown: Bool) {
        if !shown, CallController.shared.protectsChat(host: entry.host, deviceId: entry.deviceId, agentId: agent.id) {
            error = AppError.callActive.message
            return
        }
        pending[agent.id] = shown
        error = nil
        let service = chat.service(for: entry)
        Task {
            defer { pending.removeValue(forKey: agent.id) }
            do {
                let result = try await service.setAgent(id: agent.id, request: AgentVisibilityRequest(shown: shown))
                if !result.agent.shown { await AppDelegate.clearHidden(host: entry.host, agentID: agent.id) }
                if chat.host != entry.host {
                    if let list = try? await service.conversations(), chat.host != entry.host {
                        Pairings.shared.refreshAgents(list.conversations, host: entry.host, deviceId: entry.deviceId)
                    }
                }
                revision += 1
                if let index = candidates?.firstIndex(where: { $0.id == agent.id }) { candidates?[index] = result.agent }
            } catch { self.error = AppError.map(error).message }
        }
    }
}

struct PairedHostSettingsRows: View {
    @State private var showsPairing = false

    var body: some View {
        SettingsSection("Paired hosts") {
            ForEach(Pairings.shared.entries, id: \.host) { entry in
                NavigationLink { HostDetail(pairing: entry) } label: { PairedHostRow(entry: entry) }
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
