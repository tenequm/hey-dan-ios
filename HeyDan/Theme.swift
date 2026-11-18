import SwiftUI

// Compilation cache benchmark.
/// The voice page's "te" skin, dark colorway: the colours and the mono typeface the call readout and the Live
/// Activity still use.
enum Theme {
    static let card = Color(hex: 0x1C1C1C)
    static let text = Color(hex: 0xF1EFE9)
    static let muted = Color(hex: 0x9A978F)

    static let screen = Color(hex: 0x0B0B0B)
    static let screenSoft = Color(hex: 0xC4C1B9)
    static let outline = Color(hex: 0x4A4843)

    static let orange = Color(hex: 0xFF4F1F)
    static let onOrange = Color(hex: 0x1A0A04)
    static let think = Color(hex: 0x8CC2FF)
    static let ok = Color(hex: 0x37B24D)
    static let ledOff = Color(hex: 0x3D3D3D)
    static let error = Color(hex: 0xFF6F8E)

    static func mono(_ size: CGFloat, medium: Bool = false) -> Font {
        .custom(medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular", size: size)
    }
}

/// The readout chip's colours, the same on the call screen and in the Live Activity.
struct ChipPalette {
    var ink = Theme.screenSoft
    var fill = Color.clear
    var outline = Theme.outline
    var dot: Color?

    static let quiet = ChipPalette()
    /// The caller has the line: a lit chip with an orange dot.
    static let you = ChipPalette(ink: Theme.screen, fill: Theme.text, outline: .clear, dot: Theme.orange)
    static let speaking = ChipPalette(ink: Theme.orange, outline: Theme.orange.opacity(0.6))
    static let thinking = ChipPalette(ink: Theme.think, outline: Theme.think.opacity(0.55))
    static let error = ChipPalette(ink: Theme.error, outline: Theme.error)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension View {
    /// CSS letter-spacing in em.
    func spacing(_ em: CGFloat, size: CGFloat) -> some View { tracking(em * size) }
}

/// Children in rows that wrap, like CSS `flex-wrap` with `align-items: center`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            size.width = min(size.width, width)
            // The tolerance keeps a row measured at its own width from wrapping on rounding when it is placed.
            if !row.indices.isEmpty, row.width + spacing + size.width > width + 0.5 {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
