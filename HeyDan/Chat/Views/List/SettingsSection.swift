import SwiftUI

struct SettingsSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String = "", footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s2) {
            if !title.isEmpty {
                Text(title).textRole(theme.type.footnote, theme.weight.medium)
                    .foregroundStyle(theme.color.textSecondary).padding(.horizontal, theme.space.s2)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color.surfaceGrouped, in: RoundedRectangle(cornerRadius: theme.radius.group))
            if let footer {
                Text(footer).textRole(theme.type.footnote).foregroundStyle(theme.color.textSecondary)
                    .padding(.horizontal, theme.space.s4)
            }
        }
    }
}

struct SettingsRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let icon: String
    var detail: String?
    var subtitle: String?
    var navigates = false
    var destructive = false

    var body: some View {
        HStack(spacing: theme.space.s3) {
            Image(systemName: icon).frame(width: theme.control.glassIcon)
            VStack(alignment: .leading, spacing: theme.space.s1) {
                Text(title).textRole(theme.type.body)
                if let subtitle {
                    Text(subtitle).textRole(theme.type.footnote).foregroundStyle(theme.color.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if let detail { Text(detail).textRole(theme.type.footnote).foregroundStyle(theme.color.textSecondary) }
            if navigates { Image(systemName: "chevron.right").foregroundStyle(theme.color.chevron) }
        }
        .padding(.horizontal, theme.space.s4).padding(.vertical, theme.space.s3)
        .frame(minHeight: theme.control.touchTarget + theme.space.s3)
        .foregroundStyle(destructive ? theme.color.danger : theme.color.textPrimary)
        .contentShape(Rectangle())
    }
}
