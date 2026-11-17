import SwiftUI
import HeyDanCore

/// H4a owns the paired root and conversation navigation.
struct ConversationList: View {
    @Environment(ChatController.self) private var chat
    var body: some View {
        NavigationStack(path: Binding(get: { chat.openConversationId.map { [$0] } ?? [] }, set: { ids in if let id = ids.last { chat.openConversation(id) } else { chat.closeConversation() } })) {
            List(chat.conversations, id: \.id) { conversation in
                NavigationLink(conversation.agent.name, value: conversation.id)
            }
            .navigationDestination(for: String.self) { id in
                if let conversation = chat.conversations.first(where: { $0.id == id }) { ThreadView(conversation: conversation) }
            }
            .task(id: chat.openConversationId) {
                if chat.openConversationId == nil { await AppDelegate.requestPermission() }
            }
        }
    }
}
