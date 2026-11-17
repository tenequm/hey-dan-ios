import SwiftUI
import HeyDanCore

/// H4a owns the thread; H6 connects its call action to the paired target.
struct ThreadView: View {
    let conversation: Conversation
    var body: some View {
        Color.clear
            .navigationTitle(conversation.agent.name)
            .toolbar { ThreadCallButton(conversation: conversation) }
    }
}
