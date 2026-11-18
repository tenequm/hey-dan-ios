import SwiftUI
import HeyDanCore

struct ConversationList: View {
    @Environment(ChatController.self) private var chat
    @Environment(\.theme) private var theme
    @State private var tab = Tab.chats
    @State private var query = ""
    @State private var pairing = false

    private enum Tab { case chats, settings, search }

    private var path: Binding<[String]> {
        Binding(get: { chat.openConversationId.map { [$0] } ?? [] }, set: {
            if let id = $0.last { chat.openConversation(id) } else { chat.closeConversation() }
        })
    }

    private var conversations: [Conversation] {
        guard tab == .search, !query.isEmpty else { return chat.conversations }
        return chat.conversations.filter {
            $0.agent.name.localizedCaseInsensitiveContains(query) ||
                $0.lastMessage?.preview.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        NavigationStack(path: path) {
            Group {
                if tab == .settings {
                    PairedSettingsSection()
                } else {
                    VStack(spacing: 0) {
                        header
                        if tab == .search {
                            TextField("Search chats", text: $query)
                                .textRole(theme.type.body)
                                .padding(theme.space.s3)
                                .background(theme.color.surfaceInput, in: Capsule())
                                .padding(.horizontal, theme.space.s4)
                                .accessibilityLabel("Search chats")
                        }
                        if chat.connectionState == .reconnecting || chat.connectionState == .disconnected || chat.error != nil {
                            Label(connectionNotice, systemImage: "wifi.slash")
                                .textRole(theme.type.footnote, theme.weight.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(theme.space.s3_5)
                                .background(theme.color.surfaceCard, in: RoundedRectangle(cornerRadius: theme.radius.l))
                                .padding(.horizontal, theme.space.s4)
                        }
                        if conversations.isEmpty {
                            emptyState
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    HStack {
                                        Text(chat.host?.host() ?? "Host").textRole(theme.type.label, theme.weight.medium)
                                        Rectangle().fill(theme.color.border).frame(height: 1)
                                    }
                                    .foregroundStyle(theme.color.textTertiary)
                                    .padding(.horizontal, theme.space.s5)
                                    .padding(.top, theme.space.s4)
                                    .padding(.bottom, theme.space.s1_5)
                                    ForEach(conversations, id: \.id) { conversation in
                                        Button { chat.openConversation(conversation.id) } label: {
                                            ConversationRow(conversation: conversation, status: chat.statuses[conversation.id])
                                        }
                                        .buttonStyle(.plain)
                                        .opacity(chat.connectionState == .reconnecting ? 0.55 : 1)
                                        if conversation.id != conversations.last?.id {
                                            Rectangle().fill(theme.color.borderSubtle).frame(height: 1)
                                                .padding(.leading, theme.space.s5)
                                        }
                                    }
                                }
                            }
                            .refreshable { await chat.refresh() }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { tabBar }
            .background(theme.color.surface.ignoresSafeArea())
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                if let conversation = chat.conversations.first(where: { $0.id == id }) {
                    ThreadView(conversation: conversation)
                }
            }
            .task(id: chat.openConversationId) {
                if chat.openConversationId == nil { await AppDelegate.requestPermission() }
            }
        }
        .foregroundStyle(theme.color.textPrimary)
        .tint(theme.color.accentText)
        .sheet(isPresented: $pairing) { PairingView() }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var header: some View {
        HStack(spacing: theme.space.s1_5) {
            if chat.connectionState == .reconnecting || chat.connectionState == .connecting {
                ProgressView().controlSize(.small)
                Text(chat.connectionState == .connecting ? "Connecting…" : "Reconnecting…")
                    .textRole(theme.type.body, theme.weight.bold).foregroundStyle(theme.color.textSecondary)
            } else {
                Text("Hey").textRole(theme.type.title, theme.weight.bold)
                Text("Dan").textRole(theme.type.title, theme.weight.medium).foregroundStyle(theme.color.textSecondary)
            }
            Spacer()
            GlassIconButton(title: "Pair a host", systemImage: "plus") { pairing = true }
        }
        .padding(.leading, theme.space.s5).padding(.trailing, theme.space.s4)
        .padding(.vertical, theme.space.s1_5)
    }

    private var connectionNotice: String {
        if let error = chat.error { return error.message }
        return "\(chat.host?.host() ?? "Your host") is unreachable. Messages you send now go out when it is back."
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: theme.space.s2) {
                Text(query.isEmpty || tab != .search ? "No agents yet" : "No matching chats")
                    .textRole(theme.type.title, theme.weight.bold)
                if query.isEmpty || tab != .search {
                    Text("Pair this phone with a host to chat with its agents. Ask Dan for a pairing link with /pair.")
                        .textRole(theme.type.body).foregroundStyle(theme.color.textSecondary)
                    Button("Pair a host") { pairing = true }
                        .buttonStyle(.borderedProminent).tint(theme.color.accent)
                        .padding(.top, theme.space.s4)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, theme.space.s8)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await chat.refresh() }
    }

    private var tabBar: some View {
        let height = theme.control.touchTarget + theme.space.s4 + theme.space.s0_5
        return HStack(spacing: theme.space.s3) {
            HStack(spacing: theme.space.s1) {
                tabButton(.chats, "Chats", "bubble.left.and.bubble.right")
                tabButton(.settings, "Settings", "gearshape")
            }
            .padding(theme.space.s1).frame(height: height).glassCapsule(theme)
            Button { tab = .search } label: {
                Image(systemName: "magnifyingglass").frame(width: height, height: height)
                    .foregroundStyle(tab == .search ? theme.color.accentText : theme.color.icon)
                    .glassCapsule(theme)
            }
            .accessibilityLabel("Search").accessibilityAddTraits(tab == .search ? .isSelected : [])
        }
        .buttonStyle(.plain)
        .padding(.horizontal, theme.space.s5).padding(.bottom, theme.space.s2)
    }

    private func tabButton(_ value: Tab, _ title: String, _ icon: String) -> some View {
        Button { tab = value } label: {
            VStack(spacing: theme.space.s0_5) {
                Image(systemName: icon).font(.system(size: theme.control.glassIcon))
                Text(title).textRole(theme.type.micro, theme.weight.semibold)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(tab == value ? theme.color.accentText : theme.color.iconMuted)
            .background(tab == value ? theme.color.accentSoft : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}

struct AgentAvatar: View {
    @Environment(\.theme) private var theme
    let name: String

    var body: some View {
        Text(name.prefix(1).uppercased()).textRole(theme.type.micro, theme.weight.bold)
            .frame(width: theme.space.s5, height: theme.space.s5)
            .background(theme.color.surfaceGrouped, in: Circle())
            .overlay { Circle().strokeBorder(theme.color.border) }
            .accessibilityHidden(true)
    }
}

struct ConversationRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: Conversation
    var status: Status?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s1) {
            HStack(spacing: theme.space.s2) {
                AgentAvatar(name: conversation.agent.name)
                Text(conversation.agent.name).textRole(theme.type.body, theme.weight.medium)
                Spacer()
                trailing.textRole(theme.type.label, theme.weight.bold)
            }
            if let preview = conversation.lastMessage?.preview {
                Text(preview).textRole(theme.type.label).foregroundStyle(theme.color.textSecondary)
                    .lineLimit(2).padding(.leading, theme.space.s5 + theme.space.s2)
            }
        }
        .padding(.horizontal, theme.space.s5).padding(.vertical, theme.space.s2_5)
        .foregroundStyle(theme.color.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityIdentifier(AXID.conversation(conversation.id))
    }

    @ViewBuilder private var trailing: some View {
        if let status, status.state == .working {
            HStack(spacing: theme.space.s1) {
                if reduceMotion { Image(systemName: "circle.dashed") }
                else { ProgressView().controlSize(.mini).tint(theme.color.statusWorking) }
                if status.at > 0 {
                    Text(Date(timeIntervalSince1970: Double(status.at) / 1000), style: .timer)
                        .monospacedDigit().fixedSize()
                }
            }
            .foregroundStyle(theme.color.statusWorking).accessibilityIdentifier(AXID.status)
        } else if status?.state == .waiting {
            Label("Input", systemImage: "questionmark.bubble").foregroundStyle(theme.color.statusInput)
                .accessibilityIdentifier(AXID.status)
        } else if conversation.unread > 0 && conversation.lastMessage?.role == .agent {
            Label("Done", systemImage: "checkmark.circle").foregroundStyle(theme.color.statusDone)
        } else if let last = conversation.lastMessage {
            Text(Date(timeIntervalSince1970: Double(last.at) / 1000), style: .time)
                .textRole(theme.type.label).foregroundStyle(theme.color.textTertiary)
        }
    }

    private var accessibilitySummary: String {
        var parts = [conversation.agent.name]
        if status?.state == .working { parts.append(status?.label ?? "Working") }
        else if status?.state == .waiting { parts.append("Input") }
        else if conversation.unread > 0, conversation.lastMessage?.role == .agent { parts.append("Done") }
        if let preview = conversation.lastMessage?.preview { parts.append(preview) }
        if conversation.unread > 0 { parts.append("\(conversation.unread) unread") }
        return parts.joined(separator: ", ")
    }
}
