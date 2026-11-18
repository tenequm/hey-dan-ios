import SwiftUI
import MarkdownView

struct MessageBody: View {
    let text: String
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        SelectableMarkdown(text: text, theme: markdownTheme)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
    }

    private var markdownTheme: MarkdownTheme {
        var markdown = MarkdownTheme()
        let size = theme.type.body.size * scale
        let body = UIFont(name: theme.type.face(theme.weight.regular), size: size) ?? .systemFont(ofSize: size)
        let bold = UIFont(name: theme.type.face(theme.weight.bold), size: size) ?? .boldSystemFont(ofSize: size)
        markdown.fonts.body = body
        markdown.fonts.bold = bold
        markdown.fonts.italic = UIFont(descriptor: body.fontDescriptor.withSymbolicTraits(.traitItalic) ?? body.fontDescriptor, size: size)
        markdown.fonts.title = bold.withSize(theme.type.headline.size * scale)
        markdown.fonts.largeTitle = bold.withSize(theme.type.title.size * scale)
        markdown.fonts.footnote = body.withSize(theme.type.footnote.size * scale)
        markdown.fonts.code = UIFont(name: theme.type.face(theme.weight.regular, mono: true), size: theme.type.code.size * scale)
            ?? .monospacedSystemFont(ofSize: theme.type.code.size * scale, weight: .regular)
        markdown.fonts.codeInline = markdown.fonts.code
        markdown.colors.body = UIColor(theme.color.textPrimary)
        markdown.colors.code = UIColor(theme.color.textPrimary)
        markdown.colors.highlight = UIColor(theme.color.accentText)
        markdown.colors.emphasis = UIColor(theme.color.textPrimary)
        markdown.colors.codeBackground = UIColor(theme.color.codeSurface)
        markdown.colors.codeBlockBackground = UIColor(theme.color.codeSurface)
        markdown.colors.codeBlockBarBackground = UIColor(theme.color.codeSurface)
        markdown.table.headerBackgroundColor = UIColor(theme.color.surfaceCard)
        markdown.table.borderColor = UIColor(theme.color.border)
        markdown.syntax.comment = UIColor(theme.color.syntaxComment)
        markdown.syntax.keyword = UIColor(theme.color.syntaxKeyword)
        markdown.syntax.string = UIColor(theme.color.syntaxString)
        markdown.syntax.number = UIColor(theme.color.syntaxNumber)
        markdown.syntax.type = UIColor(theme.color.syntaxType)
        markdown.syntax.attribute = UIColor(theme.color.syntaxFunction)
        markdown.syntax.meta = UIColor(theme.color.syntaxKeyword)
        markdown.syntax.variable = UIColor(theme.color.textPrimary)
        markdown.spacings.paragraph = theme.space.s2
        markdown.spacings.headingBefore = theme.space.s2
        return markdown
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
