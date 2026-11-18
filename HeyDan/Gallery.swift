#if DEBUG
import SwiftUI

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
                default: Text("No gallery for \(name)").textRole(theme.type.body).foregroundStyle(theme.color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.color.surface)
        .galleryItem("viewport")
        .onPreferenceChange(GalleryFrames.self) { save($0) }
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
