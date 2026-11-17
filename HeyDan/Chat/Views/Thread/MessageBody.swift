import SwiftUI
import MarkdownView

/// H4a owns the renderer theme, link policy and accessibility.
struct MessageBody: View {
    let text: String
    var body: some View { MarkdownView(text) }
}
