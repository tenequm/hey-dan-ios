import SwiftUI
import HeyDanCore

struct ConversationList: View {
    @Environment(ChatController.self) private var chat

    private var path: Binding<[String]> {
        Binding(get: { chat.openConversationId.map { [$0] } ?? [] }, set: {
            if let id = $0.last { chat.openConversation(id) } else { chat.closeConversation() }
        })
    }

    var body: some View {
        NavigationStack(path: path) {
            List {
                if chat.connectionState != .connected {
                    Text(connectionLabel).font(Theme.sans(13)).foregroundStyle(Theme.muted)
                        .accessibilityIdentifier(AXID.connection)
                }
                ForEach(chat.conversations, id: \.id) { conversation in
                    NavigationLink(value: conversation.id) {
                        ConversationRow(conversation: conversation, status: chat.statuses[conversation.id])
                    }
                    .listRowBackground(Theme.page)
                }
            }
            .refreshable { await chat.refresh() }
            .task(id: chat.openConversationId) {
                if chat.openConversationId == nil { await AppDelegate.requestPermission() }
            }
            .overlay {
                if chat.conversations.isEmpty {
                    ContentUnavailableView("No conversations", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationTitle("Conversations")
            .navigationDestination(for: String.self) { id in
                if let conversation = chat.conversations.first(where: { $0.id == id }) {
                    ThreadView(conversation: conversation)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.page)
            .accessibilityIdentifier(AXID.conversationList)
        }
        .tint(Theme.orange)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var connectionLabel: String {
        if case .server(_, let body) = chat.error { return body.message }
        switch chat.connectionState {
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        case .connected: return ""
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    var status: Status?

    var body: some View {
        HStack(spacing: 12) {
            Text(conversation.agent.name.prefix(1).uppercased())
                .font(Theme.sans(22, .semibold))
                .frame(width: 44, height: 44)
                .background(Theme.card, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(conversation.agent.name).font(Theme.sans(17, .semibold))
                    Spacer()
                    if let last = conversation.lastMessage {
                        Text(Date(timeIntervalSince1970: Double(last.at) / 1000), style: .time)
                            .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    }
                }
                if let last = conversation.lastMessage {
                    Text(last.preview).font(Theme.sans(14)).foregroundStyle(Theme.muted).lineLimit(2)
                }
                if let status { StatusPill(status: status) }
            }
            if conversation.unread > 0 {
                Text("\(conversation.unread)").font(Theme.sans(13, .semibold))
                    .padding(7).background(Theme.orange, in: Capsule())
                    .accessibilityLabel("\(conversation.unread) unread")
            }
        }
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.conversation(conversation.id))
    }
}
