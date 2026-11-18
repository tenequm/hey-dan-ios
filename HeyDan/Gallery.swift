#if DEBUG
import SwiftUI
import HeyDanCore

/// `HEYDAN_GALLERY=<Component>` shows one design component in its states, for a Simulator screenshot set beside the
/// pen's (`.local/redesign/<Component>/`). Each state's frame in points goes to Caches/gallery-frames.json, so a
/// screenshot can be cut to the same box as the design's.
struct Gallery: View {
    @Environment(\.theme) private var theme
    let name: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                switch name {
                case "Tokens": TokenSpecimen()
                case "GlassIconButton":
                    GlassIconButton(title: "Back", systemImage: "chevron.left") {}
                        .galleryButton(name)
                case "ThreadCallButton": ThreadCallLabel().galleryButton(name)
                default: threadItem.frame(width: itemWidth).galleryItem(name)

                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.color.surface)
        .galleryItem("viewport")
        .onPreferenceChange(GalleryFrames.self) { save($0) }
    }

    private var itemWidth: CGFloat {
        if name.hasPrefix("ComposerView") { return 402 }
        if name.hasPrefix("AttachmentView") { return name.hasSuffix("Image") ? 240 : 280 }
        return 370
    }

    @ViewBuilder private var threadItem: some View {
        let values = ThreadPreviewValues.self
        switch name {
        case "StatusPill", "StatusPill-Inline":
            StatusPill(status: values.statusworking, style: name == "StatusPill" ? .capsule : .inline)
        case "HistoryLoader": HistoryLoader(loading: true)
        case "MessageRow-User":
            MessageRow(message: sampleUserMessage)
        case "MessageRow-Agent": MessageRow(message: values.agentMarkdown0)
        case "CodeBlock": MessageBody(text: "```bash\n# Verify the backup\nbackup check\n```")
        case "QuestionCard", "QuestionCard-Answered":
            QuestionCard(agentName: "Taylor", question: name == "QuestionCard" ? values.questionopen : values.questionanswered)
        case "OutboxRow-Sending", "OutboxRow-Failed":
            OutboxRow(entry: Outbox.Entry(host: URL(string: "https://example.invalid")!, conversationId: "sample",
                request: SendRequest(clientId: "sample", text: "Also send me the backup log.", fileIds: []),
                state: name.hasSuffix("Failed") ? .failed : .queued), retry: { _ in }, discard: { _ in })
        case "AttachmentView-Image", "AttachmentView-File":
            let isImage = name.hasSuffix("Image")
            let file = FileAttachment(id: "sample", name: isImage ? "Photo.png" : "backup.log",
                                      mimeType: isImage ? "image/png" : "text/plain", size: 48_211,
                                      kind: isImage ? .image : .file, width: 240, height: 180)
            AttachmentView(file: file, download: { _ in Self.samplePhoto })
        case "ComposerView", "ComposerView-Typing", "ComposerView-Staged", "StagedAttachmentTray":
            ComposerView(features: ["files"], send: { _, _ in false },
                         text: name.hasSuffix("Typing") ? "Please check the last backup\nand send the log." : "",
                         attachments: name.hasSuffix("Staged") || name == "StagedAttachmentTray" ?
                             [StagedAttachment(fileURL: Self.samplePhoto, name: "Photo.png", mimeType: "image/png")] : [])
        default: EmptyView()
        }
    }

    private var sampleUserMessage: Message {
        var message = ThreadPreviewValues.voiceCaller0
        message.voice = nil
        message.text = "Why did the nightly backup fail? Can you fix it before tonight?"
        return message
    }

    private static var samplePhoto: URL {
        let url = URL.cachesDirectory.appending(path: "gallery-photo.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? UIImage(systemName: "photo")?.withTintColor(.systemGray, renderingMode: .alwaysOriginal)
                .pngData()?.write(to: url, options: .atomic)
        }
        return url
    }

    private func save(_ frames: [String: CGRect]) {
        let rows = frames.mapValues { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: .sortedKeys) else { return }
        try? data.write(to: URL.cachesDirectory.appending(path: "gallery-frames.json"), options: .atomic)
    }
}

struct GalleryFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func galleryButton(_ name: String) -> some View {
        padding(EdgeInsets(top: 20, leading: 24, bottom: 28, trailing: 24))
            .galleryItem(name)
    }

    /// Marks one state for the screenshot cut, by the name its design frame has.
    func galleryItem(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: GalleryFrames.self, value: [name: proxy.frame(in: .global)])
        })
    }
}

private struct TokenSpecimen: View {
    @Environment(\.theme) private var theme
    private var roles: [(String, Tokens.TextRole, Font.Weight)] { [
        ("display", theme.type.display, .bold), ("largeTitle", theme.type.largeTitle, .bold), ("title", theme.type.title, .bold),
        ("headline", theme.type.headline, .bold), ("body", theme.type.body, .medium), ("body", theme.type.body, .regular),
        ("footnote", theme.type.footnote, .regular), ("label", theme.type.label, .bold), ("caption", theme.type.caption, .regular),
        ("micro", theme.type.micro, .regular),
    ] }
    private var swatches: [(String, Color)] { [
        ("surface", theme.color.surface), ("surfaceCard", theme.color.surfaceCard),
        ("surfaceGrouped", theme.color.surfaceGrouped), ("userBubble", theme.color.userBubble),
        ("textPrimary", theme.color.textPrimary), ("textSecondary", theme.color.textSecondary),
        ("border", theme.color.border), ("accent", theme.color.accent), ("danger", theme.color.danger),
        ("warning", theme.color.warning), ("statusWorking", theme.color.statusWorking),
        ("statusDone", theme.color.statusDone),
    ] }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s3) {
            ForEach(Array(roles.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: theme.space.s1) {
                    Text("font/\(row.0)  \(Int(row.1.size))/\(Int(row.1.linePoints))")
                        .textRole(theme.type.micro).foregroundStyle(theme.color.textTertiary)
                    Text("Dan finished the backup check").textRole(row.1, row.2).foregroundStyle(theme.color.textPrimary)
                }
            }
            Text("let mono = \"Menlo 14/20\"").textRole(theme.type.code, mono: true).foregroundStyle(theme.color.syntaxString)
                .padding(theme.space.s2)
                .background(theme.color.codeSurface, in: RoundedRectangle(cornerRadius: theme.radius.xs))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.space.s2), count: 4), spacing: theme.space.s2) {
                ForEach(swatches, id: \.0) { name, color in
                    VStack(spacing: theme.space.s1) {
                        RoundedRectangle(cornerRadius: theme.radius.s).fill(color).frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: theme.radius.s).strokeBorder(theme.color.border))
                        Text(name).textRole(theme.type.micro).foregroundStyle(theme.color.textSecondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(theme.space.s4)
        .galleryItem("Tokens")
    }
}
#endif
