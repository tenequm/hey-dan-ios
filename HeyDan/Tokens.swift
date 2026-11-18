import SwiftUI
import UIKit

/// The chat look's tokens, one constant per variable in `design/hey-dan.pen` (`color/textPrimary` is
/// `Tokens.Color.textPrimary`). Colors hold the pen's Dark and Light values as RRGGBBAA and resolve against the view's
/// color scheme, so a screen follows the appearance it is shown in; UIKit takes them as `UIColor(Tokens.Color.x)`.
enum Tokens {
    enum Color {
        static let surface = themed(dark: 0x0A0A0AFF, light: 0xFCFCFCFF)
        static let surfaceCard = themed(dark: 0x111111FF, light: 0xFFFFFFFF)
        static let surfaceGrouped = themed(dark: 0x1A1B1BFF, light: 0xF4F4F5FF)
        static let surfaceSubtle = themed(dark: 0x111111FF, light: 0xFAFAFAFF)
        static let surfaceSheet = themed(dark: 0x0A0A0AFF, light: 0xFCFCFCFF)
        static let surfaceInput = themed(dark: 0x111111FF, light: 0xFFFFFFFF)
        static let userBubble = themed(dark: 0x161616FF, light: 0xEFEFF1FF)
        static let composer = themed(dark: 0x1A1B1BE6, light: 0xF4F4F5F0)
        static let composerBorder = themed(dark: 0x191919CC, light: 0xE4E4E7CC)
        static let glass = themed(dark: 0x1A1B1BE6, light: 0xF4F4F5F0)
        static let textPrimary = themed(dark: 0xF5F5F5FF, light: 0x27272AFF)
        static let textSecondary = themed(dark: 0x838383FF, light: 0x6F6F79FF)
        static let textTertiary = themed(dark: 0x818181FF, light: 0x71717BFF)
        static let placeholder = themed(dark: 0x838383FF, light: 0x6F6F79FF)
        static let border = themed(dark: 0x191919FF, light: 0xE4E4E7FF)
        static let borderSubtle = themed(dark: 0x191919B3, light: 0xE4E4E7B3)
        static let borderInput = themed(dark: 0x1E1E1EFF, light: 0xD4D4D8FF)
        static let accent = themed(dark: 0x346BF1FF, light: 0x1B4ED8FF)
        static let accentText = themed(dark: 0x4B7CF3FF, light: 0x1B4ED8FF)
        static let onAccent = themed(dark: 0xFFFFFFFF, light: 0xFFFFFFFF)
        static let accentSoft = themed(dark: 0x346BF11A, light: 0x1B4ED81A)
        static let prominent = themed(dark: 0xF5F5F5FF, light: 0x27272AFF)
        static let onProminent = themed(dark: 0x0A0A0AFF, light: 0xFCFCFCFF)
        static let secondaryFill = themed(dark: 0x111111FF, light: 0xFAFAFAFF)
        static let danger = themed(dark: 0xFF6467FF, light: 0xC10007FF)
        static let dangerSurface = themed(dark: 0x301214FF, light: 0xFCEBECFF)
        static let dangerBorder = themed(dark: 0xFB414A52, light: 0xFB2C3652)
        static let warning = themed(dark: 0xFFB900FF, light: 0xBB4D00FF)
        static let warningSurface = themed(dark: 0x312108FF, light: 0xFCF4E8FF)
        static let warningBorder = themed(dark: 0xFE9A0052, light: 0xFE9A0052)
        static let info = themed(dark: 0x51A2FFFF, light: 0x1B4ED8FF)
        static let infoSurface = themed(dark: 0x121B34FF, light: 0xE0E6F7FF)
        static let icon = themed(dark: 0xF5F5F5FF, light: 0x27272AFF)
        static let iconMuted = themed(dark: 0x818181FF, light: 0x71717BFF)
        static let chevron = themed(dark: 0x8181816B, light: 0x71717B6B)
        static let codeSurface = themed(dark: 0x111111FF, light: 0xFFFFFFFF)
        static let link = themed(dark: 0x3B70F1FF, light: 0x1B4ED8FF)
        static let backdrop = themed(dark: 0x0000007A, light: 0x00000038)
        static let disabledFill = themed(dark: 0xF5F5F51F, light: 0x27272A1F)
        static let disabledIcon = themed(dark: 0xF5F5F561, light: 0x27272A61)
        static let switchOffTrack = themed(dark: 0x2A2A2AFF, light: 0xE4E4E7FF)
        static let shadow = themed(dark: 0x00000059, light: 0x00000026)
        static let statusWorking = themed(dark: 0x00BCFFFF, light: 0x0084D1FF)
        static let statusDone = themed(dark: 0x5EE9B5FF, light: 0x007A55FF)
        static let statusInput = themed(dark: 0xA3B3FFFF, light: 0x4F39F6FF)
        static let statusConnected = themed(dark: 0x34D399FF, light: 0x059669FF)
        static let syntaxKeyword = themed(dark: 0xFF7B72FF, light: 0xCF222EFF)
        static let syntaxString = themed(dark: 0xA5D6FFFF, light: 0x0A3069FF)
        static let syntaxFunction = themed(dark: 0xD2A8FFFF, light: 0x8250DFFF)
        static let syntaxComment = themed(dark: 0x8B949EFF, light: 0x6E7781FF)
        static let syntaxNumber = themed(dark: 0x79C0FFFF, light: 0x0550AEFF)
        static let syntaxType = themed(dark: 0xFFA657FF, light: 0x953800FF)

        private static func themed(dark: UInt32, light: UInt32) -> SwiftUI.Color {
            let dark = rgba(dark), light = rgba(light)
            return SwiftUI.Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }

        fileprivate static func rgba(_ value: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: CGFloat(value & 0xFF) / 255
            )
        }
    }

    enum Canvas {
        static let panel = SwiftUI.Color(uiColor: Color.rgba(0xF4F4F5FF))
        static let text = SwiftUI.Color(uiColor: Color.rgba(0x18181BFF))
        static let textMuted = SwiftUI.Color(uiColor: Color.rgba(0x52525BFF))
        static let arrow = SwiftUI.Color(uiColor: Color.rgba(0x346BF1FF))
        static let card = SwiftUI.Color.white
    }

    enum Space {
        static let s0_5: CGFloat = 2
        static let s1: CGFloat = 4
        static let s1_5: CGFloat = 6
        static let s2: CGFloat = 8
        static let s2_5: CGFloat = 10
        static let s3: CGFloat = 12
        static let s3_5: CGFloat = 14
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
        static let s10: CGFloat = 40
    }

    enum Radius {
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 14
        static let l: CGFloat = 16
        static let bubble: CGFloat = 20
        static let group: CGFloat = 24
        static let field: CGFloat = 26
        static let composer: CGFloat = 27
        static let glass: CGFloat = 32
        static let pill: CGFloat = 999
    }

    /// Point sizes and families. The canvas draws mono in JetBrains Mono and system chrome in Inter; on the phone
    /// they are Menlo (as T3 Code on iOS) and SF Pro.
    enum Font {
        static let micro: CGFloat = 11
        static let caption: CGFloat = 12
        static let label: CGFloat = 13
        static let footnote: CGFloat = 14
        static let body: CGFloat = 16
        static let headline: CGFloat = 18
        static let title: CGFloat = 21
        static let largeTitle: CGFloat = 26
        static let display: CGFloat = 30
        static let code: CGFloat = 14
        static let family = "DM Sans"
        static let familyMono = "JetBrains Mono"
        static let familySystem = "Inter"
    }

    /// Line height as a multiple of the point size, as CSS has it.
    enum LineHeight {
        static let micro: CGFloat = 1.27
        static let caption: CGFloat = 1.33
        static let label: CGFloat = 1.31
        static let footnote: CGFloat = 1.36
        static let body: CGFloat = 1.44
        static let headline: CGFloat = 1.28
        static let title: CGFloat = 1.33
        static let largeTitle: CGFloat = 1.23
        static let display: CGFloat = 1.2
        static let code: CGFloat = 1.43
    }

    enum Weight {
        static let regular = SwiftUI.Font.Weight.regular
        static let medium = SwiftUI.Font.Weight.medium
        static let semibold = SwiftUI.Font.Weight.semibold
        static let bold = SwiftUI.Font.Weight.bold
    }

    /// One row of the pen's type scale: `font/<role>` at `lineHeight/<role>`, scaled with Dynamic Type along the
    /// system style of about its size.
    struct TextRole: Sendable {
        let size: CGFloat
        let lineHeight: CGFloat
        let textStyle: SwiftUI.Font.TextStyle

        static let micro = TextRole(size: Font.micro, lineHeight: LineHeight.micro, textStyle: .caption2)
        static let caption = TextRole(size: Font.caption, lineHeight: LineHeight.caption, textStyle: .caption)
        static let label = TextRole(size: Font.label, lineHeight: LineHeight.label, textStyle: .footnote)
        static let footnote = TextRole(size: Font.footnote, lineHeight: LineHeight.footnote, textStyle: .subheadline)
        static let body = TextRole(size: Font.body, lineHeight: LineHeight.body, textStyle: .body)
        static let headline = TextRole(size: Font.headline, lineHeight: LineHeight.headline, textStyle: .headline)
        static let title = TextRole(size: Font.title, lineHeight: LineHeight.title, textStyle: .title2)
        static let largeTitle = TextRole(size: Font.largeTitle, lineHeight: LineHeight.largeTitle, textStyle: .title)
        static let display = TextRole(size: Font.display, lineHeight: LineHeight.display, textStyle: .largeTitle)
        static let code = TextRole(size: Font.code, lineHeight: LineHeight.code, textStyle: .subheadline)

        /// The line in points, rounded as T3 Code's scale has it (16 at 1.44 is 23).
        var linePoints: CGFloat { (size * lineHeight).rounded() }
    }

    /// A fixed-size face: the bundled DM Sans for a weight (regular, medium, semibold, bold), or Menlo for code.
    static func font(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular, mono: Bool = false) -> SwiftUI.Font {
        .custom(face(weight, mono: mono), fixedSize: size)
    }

    static func uiFont(_ size: CGFloat, _ weight: SwiftUI.Font.Weight = .regular, mono: Bool = false) -> UIFont {
        UIFont(name: face(weight, mono: mono), size: size) ?? .systemFont(ofSize: size)
    }

    private static func face(_ weight: SwiftUI.Font.Weight, mono: Bool) -> String {
        if mono { return weight == .bold ? "Menlo-Bold" : "Menlo-Regular" }
        return switch weight {
        case .medium: "DMSans-Medium"
        case .semibold: "DMSans-SemiBold"
        case .bold, .heavy, .black: "DMSans-Bold"
        default: "DMSans-Regular"
        }
    }
}

/// A type role's font and line height, both scaled with Dynamic Type.
private struct TextRoleModifier: ViewModifier {
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
        content.font(Tokens.font(size, weight, mono: mono)).lineHeight(.exact(points: line))
    }
}

extension View {
    /// `.textRole(.body, .medium)`: the pen's `font/body` at `lineHeight/body` in DM Sans Medium.
    func textRole(_ role: Tokens.TextRole, _ weight: Font.Weight = .regular, mono: Bool = false) -> some View {
        modifier(TextRoleModifier(role, weight: weight, mono: mono))
    }
}
