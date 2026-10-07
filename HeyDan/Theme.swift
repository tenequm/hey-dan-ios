import SwiftUI

/// The voice page's "te" skin, dark colorway: tokens, the two bundled typefaces and the
/// hardware-like pieces (key caps, LED, dot matrix) the screens are built from.
enum Theme {
    static let page = Color(hex: 0x0E0E0E)
    static let card = Color(hex: 0x1C1C1C)
    static let border = Color(hex: 0x333333)
    static let text = Color(hex: 0xF1EFE9)
    static let muted = Color(hex: 0x9A978F)

    static let screen = Color(hex: 0x0B0B0B)
    static let screenRing = Color(hex: 0x101010)
    static let screenSoft = Color(hex: 0xC4C1B9)
    static let screenDim = Color(hex: 0x8A877F)
    static let screenRule = Color(hex: 0x242424)
    static let outline = Color(hex: 0x4A4843)
    static let stillDot = Color(hex: 0x5C5A54)

    static let orange = Color(hex: 0xFF4F1F)
    static let orangeEdge = Color(hex: 0xB83812)
    static let onOrange = Color(hex: 0x1A0A04)
    static let think = Color(hex: 0x8CC2FF)
    static let ok = Color(hex: 0x37B24D)
    static let ledOff = Color(hex: 0x3D3D3D)
    static let error = Color(hex: 0xFF6F8E)

    static let cap = Color(hex: 0x2E2E2E)
    static let capEdge = Color(hex: 0x101010)
    static let capDark = Color(hex: 0x3A3A3A)
    static let capDarkEdge = Color(hex: 0x141414)
    static let dotOff = Color(hex: 0x1D1D1D)
    static let switchOff = Color(hex: 0x5A5853)

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Hanken Grotesk", size: size).weight(weight)
    }

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

/// The black LCD window: inset shadow and a hairline ring.
struct InsetWell: ViewModifier {
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius)
                .fill(Theme.screen.shadow(.inner(color: .black.opacity(0.7), radius: 5, y: 2)))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.screenRing, lineWidth: 1))
        }
    }
}

/// A key cap with a solid bottom edge; pressing sinks the face onto the edge. `height` is its least height: large
/// text makes it taller.
struct KeyCapStyle: ButtonStyle {
    enum Finish { case orange, light, dark }
    var finish: Finish = .light
    var height: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        KeyCap(label: configuration.label, pressed: configuration.isPressed, finish: finish, height: height)
    }

    private struct KeyCap<Label: View>: View {
        @Environment(\.isEnabled) private var isEnabled
        let label: Label
        let pressed: Bool
        let finish: Finish
        let height: CGFloat

        var body: some View {
            let (face, edge, ink, glow): (Color, Color, Color, Color) = switch finish {
            case .orange: (Theme.orange, Theme.orangeEdge, Theme.onOrange, Theme.orange.opacity(0.25))
            case .light: (Theme.cap, Theme.capEdge, Theme.text, .black.opacity(0.2))
            case .dark: (Theme.capDark, Theme.capDarkEdge, Theme.text, .black.opacity(0.2))
            }
            let sink: CGFloat = pressed && isEnabled ? 3 : 0
            label
                .font(Theme.sans(14, .medium))
                .spacing(0.01, size: 14)
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(cornerRadius: 6).fill(face))
                .offset(y: sink)
                .padding(.bottom, 4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(edge)
                        .padding(.top, 4)
                        .shadow(color: sink > 0 ? .clear : glow, radius: 5, y: 2)
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.08), value: pressed)
        }
    }
}

struct LED: View {
    let on: Bool

    var body: some View {
        Circle()
            .fill(on ? Theme.orange : Theme.ledOff)
            .frame(width: 7, height: 7)
            .shadow(color: on ? Theme.orange.opacity(0.8) : .clear, radius: 3)
    }
}

/// A grid of round dots; `pattern` rows use '#' for lit, '+' for half and '.' for off.
struct DotMatrix: View {
    let pattern: [String]
    private let dot: CGFloat = 3
    private let gap: CGFloat = 1

    var body: some View {
        let rows = pattern.map { row in row.map { $0 == "#" ? 1.0 : $0 == "+" ? 0.5 : 0 } }
        let cols = rows.map(\.count).max() ?? 0
        let pitch = dot + gap
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, level) in row.enumerated() {
                    let lit = level > 0.05
                    let r = dot / 2 * 0.9 * (level > 0.5 ? 1.1 : 1)
                    let center = CGPoint(x: CGFloat(x) * pitch + dot / 2, y: CGFloat(y) * pitch + dot / 2)
                    let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                    if lit {
                        var glow = context
                        glow.addFilter(.shadow(color: Theme.orange.opacity(0.7 * level), radius: 1.5))
                        glow.fill(circle, with: .color(Theme.orange.opacity(level)))
                    } else {
                        context.fill(circle, with: .color(Theme.dotOff.opacity(0.6)))
                    }
                }
            }
        }
        .frame(width: CGFloat(cols) * pitch - gap, height: CGFloat(rows.count) * pitch - gap)
        .accessibilityHidden(true)
    }
}

/// Text swept by a lighter band, like the page's shimmering readout; plain text with Reduce Motion.
struct ShimmerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let base: Color
    let highlight: Color
    private let period = 1.4

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(base)
        } else {
            sweep
        }
    }

    private var sweep: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let start = -1 + 2 * t
            Text(text).foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: base, location: 0),
                        .init(color: base, location: 0.35),
                        .init(color: highlight, location: 0.5),
                        .init(color: base, location: 0.65),
                        .init(color: base, location: 1),
                    ],
                    startPoint: UnitPoint(x: start, y: 0.5),
                    endPoint: UnitPoint(x: start + 1, y: 0.5)
                )
            )
        }
    }
}

/// The readout chip's dot: breathes while the line is live, still when muted.
struct PulseDot: View {
    let color: Color
    var still = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .modifier(Breathing(active: !still, period: 1.4, dimmest: 0.35, smallest: 0.85))
    }
}

/// Fades (and optionally shrinks) its content in and out on a sine, redrawn at 15 fps: only the opacity and scale
/// change, never the content. Still, at full strength, when inactive or with Reduce Motion.
struct Breathing: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    let period: Double
    var dimmest = 0.35
    var brightest = 1.0
    var smallest: CGFloat = 1

    func body(content: Content) -> some View {
        let paused = !active || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { context in
            let wave = paused ? 1 : 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / period)
            content
                .opacity(paused ? 1 : dimmest + (brightest - dimmest) * wave)
                .scaleEffect(smallest + (1 - smallest) * wave)
        }
    }
}

/// The page's on/off switch: a key-cap face with a label that wraps, and a track whose knob slides.
struct KeySwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeySwitch(configuration: configuration)
    }

    private struct KeySwitch: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 6) {
                    configuration.label
                        .font(Theme.sans(13))
                        .lineHeight(.multiple(factor: 1.25))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Capsule()
                        .fill((on ? Theme.orange : Theme.switchOff).shadow(.inner(color: .black.opacity(0.25), radius: 1, y: 1)))
                        .frame(width: 34, height: 20)
                        .overlay(alignment: on ? .trailing : .leading) {
                            Circle()
                                .fill(.white)
                                .frame(width: 16, height: 16)
                                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                                .padding(2)
                        }
                        .animation(.easeOut(duration: 0.15), value: on)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.cap)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.capEdge).offset(y: 2))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.55)
            .accessibilityValue(on ? "on" : "off")
            .accessibilityAddTraits(.isToggle)
        }
    }
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
