import SwiftUI

extension Theme {
    static let dark = Tokens()
}

extension EnvironmentValues {
    @Entry var theme: Tokens = Theme.dark
}

struct Tokens {
    var color = Color()
    var space = Space()
    var radius = Radius()
    var type = Typography()
    var weight = Weight()
    var control = Control()

    struct Color {
        // Trailing comments preserve the first design pass's unreviewed Light samples.
        var surface = rgba(0x0A0A0AFF) // Light: #FCFCFCFF
        var surfaceCard = rgba(0x111111FF) // Light: #FFFFFFFF
        var surfaceGrouped = rgba(0x1A1B1BFF) // Light: #F4F4F5FF
        var surfaceSubtle = rgba(0x111111FF) // Light: #FAFAFAFF
        var surfaceSheet = rgba(0x0A0A0AFF) // Light: #FCFCFCFF
        var surfaceInput = rgba(0x111111FF) // Light: #FFFFFFFF
        var userBubble = rgba(0x161616FF) // Light: #EFEFF1FF
        var composer = rgba(0x1A1B1BE6) // Light: #F4F4F5F0
        var composerBorder = rgba(0x191919CC) // Light: #E4E4E7CC
        var glass = rgba(0x1A1B1BE6) // Light: #F4F4F5F0
        var textPrimary = rgba(0xF5F5F5FF) // Light: #27272AFF
        var textSecondary = rgba(0x838383FF) // Light: #6F6F79FF
        var textTertiary = rgba(0x818181FF) // Light: #71717BFF
        var placeholder = rgba(0x838383FF) // Light: #6F6F79FF
        var border = rgba(0x191919FF) // Light: #E4E4E7FF
        var borderSubtle = rgba(0x191919B3) // Light: #E4E4E7B3
        var borderInput = rgba(0x1E1E1EFF) // Light: #D4D4D8FF
        var accent = rgba(0x346BF1FF) // Light: #1B4ED8FF
        var accentText = rgba(0x4B7CF3FF) // Light: #1B4ED8FF
        var onAccent = rgba(0xFFFFFFFF) // Light: #FFFFFFFF
        var accentSoft = rgba(0x346BF11A) // Light: #1B4ED81A
        var prominent = rgba(0xF5F5F5FF) // Light: #27272AFF
        var onProminent = rgba(0x0A0A0AFF) // Light: #FCFCFCFF
        var secondaryFill = rgba(0x111111FF) // Light: #FAFAFAFF
        var danger = rgba(0xFF6467FF) // Light: #C10007FF
        var callEnd = rgba(0xFF453AFF)
        var dangerSurface = rgba(0x301214FF) // Light: #FCEBECFF
        var dangerBorder = rgba(0xFB414A52) // Light: #FB2C3652
        var warning = rgba(0xFFB900FF) // Light: #BB4D00FF
        var warningSurface = rgba(0x312108FF) // Light: #FCF4E8FF
        var warningBorder = rgba(0xFE9A0052) // Light: #FE9A0052
        var info = rgba(0x51A2FFFF) // Light: #1B4ED8FF
        var infoSurface = rgba(0x121B34FF) // Light: #E0E6F7FF
        var icon = rgba(0xF5F5F5FF) // Light: #27272AFF
        var iconMuted = rgba(0x818181FF) // Light: #71717BFF
        var chevron = rgba(0x8181816B) // Light: #71717B6B
        var codeSurface = rgba(0x111111FF) // Light: #FFFFFFFF
        var link = rgba(0x3B70F1FF) // Light: #1B4ED8FF
        var backdrop = rgba(0x0000007A) // Light: #00000038
        var disabledFill = rgba(0xF5F5F51F) // Light: #27272A1F
        var disabledIcon = rgba(0xF5F5F561) // Light: #27272A61
        var switchOffTrack = rgba(0x2A2A2AFF) // Light: #E4E4E7FF
        var shadow = rgba(0x00000059) // Light: #00000026
        var statusWorking = rgba(0x00BCFFFF) // Light: #0084D1FF
        var statusDone = rgba(0x5EE9B5FF) // Light: #007A55FF
        var statusInput = rgba(0xA3B3FFFF) // Light: #4F39F6FF
        var statusConnected = rgba(0x34D399FF) // Light: #059669FF
        var syntaxKeyword = rgba(0xFF7B72FF) // Light: #CF222EFF
        var syntaxString = rgba(0xA5D6FFFF) // Light: #0A3069FF
        var syntaxFunction = rgba(0xD2A8FFFF) // Light: #8250DFFF
        var syntaxComment = rgba(0x8B949EFF) // Light: #6E7781FF
        var syntaxNumber = rgba(0x79C0FFFF) // Light: #0550AEFF
        var syntaxType = rgba(0xFFA657FF) // Light: #953800FF
    }

    struct Control {
        var touchTarget: CGFloat = 44
        var glassIcon: CGFloat = 22
        var phoneIcon: CGFloat = 17
        var callLabel: CGFloat = 15
    }

    enum Canvas {
        static let panel = rgba(0xF4F4F5FF)
        static let text = rgba(0x18181BFF)
        static let textMuted = rgba(0x52525BFF)
        static let arrow = rgba(0x346BF1FF)
        static let card = SwiftUI.Color.white
    }

    struct Space {
        var s0_5: CGFloat = 2
        var s1: CGFloat = 4
        var s1_5: CGFloat = 6
        var s2: CGFloat = 8
        var s2_5: CGFloat = 10
        var s3: CGFloat = 12
        var s3_5: CGFloat = 14
        var s4: CGFloat = 16
        var s5: CGFloat = 20
        var s6: CGFloat = 24
        var s8: CGFloat = 32
        var s10: CGFloat = 40
    }

    struct Radius {
        var xs: CGFloat = 8
        var s: CGFloat = 12
        var m: CGFloat = 14
        var l: CGFloat = 16
        var bubble: CGFloat = 20
        var group: CGFloat = 24
        var field: CGFloat = 26
        var composer: CGFloat = 27
        var glass: CGFloat = 32
        var pill: CGFloat = 999
    }

    struct Weight {
        var regular = SwiftUI.Font.Weight.regular
        var medium = SwiftUI.Font.Weight.medium
        var semibold = SwiftUI.Font.Weight.semibold
        var bold = SwiftUI.Font.Weight.bold
    }

    struct Typography {
        var family = "DMSans"
        var familyMono = "Menlo"
        var familySystem = SwiftUI.Font.Design.default
        var micro = TextRole(size: 11, lineHeight: 1.27, textStyle: .caption2)
        var caption = TextRole(size: 12, lineHeight: 1.33, textStyle: .caption)
        var label = TextRole(size: 13, lineHeight: 1.31, textStyle: .footnote)
        var footnote = TextRole(size: 14, lineHeight: 1.36, textStyle: .subheadline)
        var body = TextRole(size: 16, lineHeight: 1.44, textStyle: .body)
        var headline = TextRole(size: 18, lineHeight: 1.28, textStyle: .headline)
        var title = TextRole(size: 21, lineHeight: 1.33, textStyle: .title2)
        var largeTitle = TextRole(size: 26, lineHeight: 1.23, textStyle: .title)
        var display = TextRole(size: 30, lineHeight: 1.2, textStyle: .largeTitle)
        var code = TextRole(size: 14, lineHeight: 1.43, textStyle: .subheadline)

        func face(_ weight: SwiftUI.Font.Weight, mono: Bool = false) -> String {
            if mono { return weight == .bold ? "\(familyMono)-Bold" : "\(familyMono)-Regular" }
            let suffix = switch weight {
            case .medium: "Medium"
            case .semibold: "SemiBold"
            case .bold, .heavy, .black: "Bold"
            default: "Regular"
            }
            return "\(family)-\(suffix)"
        }
    }

    struct TextRole {
        let size: CGFloat
        let lineHeight: CGFloat
        let textStyle: SwiftUI.Font.TextStyle

        var linePoints: CGFloat { (size * lineHeight).rounded() }
    }
}

private func rgba(_ value: UInt32) -> SwiftUI.Color {
    SwiftUI.Color(.sRGB, red: Double(value >> 24) / 255, green: Double(value >> 16 & 255) / 255,
                  blue: Double(value >> 8 & 255) / 255, opacity: Double(value & 255) / 255)
}

private struct TextRoleModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var line: CGFloat
    let weight: Font.Weight
    let mono: Bool

    init(_ role: Tokens.TextRole, weight: Font.Weight, mono: Bool) {
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.textStyle)
        _line = ScaledMetric(wrappedValue: role.linePoints, relativeTo: role.textStyle)
        self.weight = weight
        self.mono = mono
    }

    func body(content: Content) -> some View {
        content.font(.custom(theme.type.face(weight, mono: mono), fixedSize: size)).lineHeight(.exact(points: line))
    }
}

extension View {
    func textRole(_ role: Tokens.TextRole, _ weight: Font.Weight = .regular, mono: Bool = false) -> some View {
        modifier(TextRoleModifier(role, weight: weight, mono: mono))
    }
}
