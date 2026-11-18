#if DEBUG
import SwiftUI

/// `HEYDAN_GALLERY=<Component>` shows one design component in its states, for a Simulator screenshot set beside the
/// pen's (`.local/redesign/<Component>/`). Each state's frame in points goes to Caches/gallery-frames.json, so a
/// screenshot can be cut to the same box as the design's.
struct Gallery: View {
    let name: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                switch name {
                case "Tokens": TokenSpecimen()
                case "GlassIconButton":
                    GlassIconButton(title: "Back", systemImage: "chevron.left") {}
                        .galleryButton(name)
                case "ThreadCallButton": ThreadCallLabel().galleryButton(name)
                default: Text("No gallery for \(name)").textRole(.body).foregroundStyle(Tokens.Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.Color.surface)
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
    private let roles: [(String, Tokens.TextRole, Font.Weight)] = [
        ("display", .display, .bold), ("largeTitle", .largeTitle, .bold), ("title", .title, .bold),
        ("headline", .headline, .bold), ("body", .body, .medium), ("body", .body, .regular),
        ("footnote", .footnote, .regular), ("label", .label, .bold), ("caption", .caption, .regular),
        ("micro", .micro, .regular),
    ]
    private let swatches: [(String, Color)] = [
        ("surface", Tokens.Color.surface), ("surfaceCard", Tokens.Color.surfaceCard),
        ("surfaceGrouped", Tokens.Color.surfaceGrouped), ("userBubble", Tokens.Color.userBubble),
        ("textPrimary", Tokens.Color.textPrimary), ("textSecondary", Tokens.Color.textSecondary),
        ("border", Tokens.Color.border), ("accent", Tokens.Color.accent), ("danger", Tokens.Color.danger),
        ("warning", Tokens.Color.warning), ("statusWorking", Tokens.Color.statusWorking),
        ("statusDone", Tokens.Color.statusDone),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ForEach(Array(roles.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("font/\(row.0)  \(Int(row.1.size))/\(Int(row.1.linePoints))")
                        .textRole(.micro).foregroundStyle(Tokens.Color.textTertiary)
                    Text("Dan finished the backup check").textRole(row.1, row.2).foregroundStyle(Tokens.Color.textPrimary)
                }
            }
            Text("let mono = \"Menlo 14/20\"").textRole(.code, mono: true).foregroundStyle(Tokens.Color.syntaxString)
                .padding(Tokens.Space.s2)
                .background(Tokens.Color.codeSurface, in: RoundedRectangle(cornerRadius: Tokens.Radius.xs))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s2), count: 4), spacing: Tokens.Space.s2) {
                ForEach(swatches, id: \.0) { name, color in
                    VStack(spacing: Tokens.Space.s1) {
                        RoundedRectangle(cornerRadius: Tokens.Radius.s).fill(color).frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.s).strokeBorder(Tokens.Color.border))
                        Text(name).textRole(.micro).foregroundStyle(Tokens.Color.textSecondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(Tokens.Space.s4)
        .galleryItem("Tokens")
    }
}
#endif
