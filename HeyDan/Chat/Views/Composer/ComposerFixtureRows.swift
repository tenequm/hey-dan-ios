#if DEBUG
import SwiftUI
import HeyDanCore

struct ComposerFixtureRows: View {
    private var chat: ChatController { .shared }

    private var messages: [Message] {
        chat.thread.compactMap { if case .message(let message) = $0 { message } else { nil } }
    }

    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(messages, id: \.id) { message in
                    if let delivery = message.delivery {
                        Text(delivery.rawValue).accessibilityIdentifier("composer.fixture.delivery")
                    }
                    ForEach(message.files, id: \.id) { file in
                        AttachmentView(file: file)
                    }
                }
                ForEach(chat.uploadProgress.keys.sorted(), id: \.self) { key in
                    ProgressView(value: chat.uploadProgress[key])
                        .accessibilityIdentifier("composer.fixture.progress")
                }
            }
        }
        .frame(height: 260)
        .accessibilityIdentifier("composer.fixture.rows")
    }
}
#endif
