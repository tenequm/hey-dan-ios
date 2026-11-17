import SwiftUI
import HeyDanCore

/// H4a owns the paired root and conversation navigation.
struct ConversationList: View {
    @Environment(ChatController.self) private var chat
    var body: some View {
        NavigationStack {
            List(chat.conversations, id: \.id) { conversation in
                NavigationLink(conversation.agent.name) { ThreadView(conversation: conversation) }
            }
        }
    }
}
