import SwiftUI
import MarkdownView

struct MessageBody: View {
    let text: String
    @ScaledMetric(relativeTo: .body) private var pointSize = 16.0

    var body: some View {
        SelectableMarkdown(text: text, theme: theme)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var theme: MarkdownTheme {
        var theme = MarkdownTheme()
        let body = UIFont(name: "HankenGrotesk-Regular", size: pointSize) ?? .systemFont(ofSize: pointSize)
        let mono = UIFont(name: "IBMPlexMono-Regular", size: pointSize) ?? .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        theme.fonts.body = body
        theme.fonts.bold = UIFont(descriptor: body.fontDescriptor.withSymbolicTraits(.traitBold) ?? body.fontDescriptor, size: pointSize)
        theme.fonts.italic = UIFont(descriptor: body.fontDescriptor.withSymbolicTraits(.traitItalic) ?? body.fontDescriptor, size: pointSize)
        theme.fonts.title = theme.fonts.bold.withSize(pointSize * 1.25)
        theme.fonts.largeTitle = theme.fonts.bold.withSize(pointSize * 1.5)
        theme.fonts.footnote = body.withSize(pointSize * 0.8)
        theme.fonts.code = mono.withSize(pointSize * 0.85)
        theme.fonts.codeInline = mono
        theme.colors.body = UIColor(Theme.text)
        theme.colors.code = UIColor(Theme.text)
        theme.colors.highlight = UIColor(Theme.orange)
        theme.colors.emphasis = UIColor(Theme.orange)
        theme.colors.codeBackground = UIColor(Theme.card)
        theme.colors.codeBlockBackground = UIColor(Theme.card)
        theme.colors.codeBlockBarBackground = UIColor(Theme.border)
        theme.table.headerBackgroundColor = UIColor(Theme.card)
        theme.table.borderColor = UIColor(Theme.border)
        return theme
    }
}

// The package's SwiftUI facade does not expose its link handler to openURL.
private struct SelectableMarkdown: UIViewRepresentable {
    let text: String
    let theme: MarkdownTheme
    @Environment(\.openURL) private var openURL

    final class Coordinator {
        var text: String?
        var theme: MarkdownTheme?
        var width: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView()
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: MarkdownTextView, context: Context) {
        view.linkHandler = { payload, _, _ in
            switch payload {
            case .url(let url): openURL(url)
            case .string(let string): if let url = URL(string: string) { openURL(url) }
            }
        }
        if context.coordinator.text != text || context.coordinator.theme != theme {
            view.setContentImmediately(MarkdownContent(markdown: text, theme: theme), theme: theme)
            context.coordinator.text = text
            context.coordinator.theme = theme
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownTextView, context: Context) -> CGSize? {
        if proposal.width == 0 { return .zero }
        if let width = proposal.width, width.isFinite, width > 0 { context.coordinator.width = width }
        let width = context.coordinator.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: ceil(uiView.boundingSize(for: width).height))
    }
}
