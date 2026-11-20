import MarkdownView
import Testing
import UIKit
@testable import HeyDan

@MainActor
struct MessageTypographyTests {
    @Test(arguments: [1.0, 1.5])
    func renderedMarkdownUsesChatMetrics(scale: CGFloat) throws {
        let theme = MessageBody.markdownTheme(.init(), scale: scale, displayScale: 3)
        let headings = (1...6).map { String(repeating: "#", count: $0) + " Level " + String($0) }
        let source = (headings + ["Body with `code` and [link](https://example.org).", "- First\n- Second"]).joined(separator: "\n\n")
        let view = MarkdownTextView()
        view.setContentImmediately(MarkdownContent(markdown: source, theme: theme), theme: theme)
        let text = view.textLabelView.attributedText

        func attributes(_ substring: String) throws -> [NSAttributedString.Key: Any] {
            let position = (text.string as NSString).range(of: substring).location
            try #require(position != NSNotFound)
            return text.attributes(at: position, effectiveRange: nil)
        }

        let headingSizes: [CGFloat] = [21, 19, 17, 15, 15, 15]
        for (index, size) in headingSizes.enumerated() {
            let attrs = try attributes("Level " + String(index + 1))
            let font = try #require(attrs[.font] as? UIFont)
            let style = try #require(attrs[.paragraphStyle] as? NSParagraphStyle)
            #expect(abs(font.pointSize - size * scale) < 0.001)
            #expect(abs(style.minimumLineHeight - size * scale * 1.35) < 0.001)
            #expect(style.maximumLineHeight == style.minimumLineHeight)
        }
        for word in ["Body", "First", "Second"] {
            let style = try #require(try attributes(word)[.paragraphStyle] as? NSParagraphStyle)
            #expect(style.minimumLineHeight == 23 * scale)
            #expect(style.maximumLineHeight == style.minimumLineHeight)
            #expect(style.lineSpacing == 0)
            if word == "First" { #expect(style.paragraphSpacing == 0) }
        }
        #expect(text.string.contains("Body with code and link."))
        let code = try attributes("code")
        let font = try #require(code[.font] as? UIFont)
        #expect(font.familyName == "Menlo")
        #expect(abs(font.pointSize - 14.4 * scale) < 0.001)
        #expect((code[.foregroundColor] as? UIColor) == theme.colors.inlineCode)
        #expect(try attributes("link")[.foregroundColor] as? UIColor == theme.colors.highlight)
    }
}
