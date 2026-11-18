import SwiftUI

struct UnpairSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let entry: Pairings.Entry
    let finished: (String?) -> Void
    @State private var contentHeight: CGFloat = 340
    @State private var working = false
    /// Set when the host could not be reached: this phone can still forget it on its own.
    @State private var unreachable: String?

    var body: some View {
        ScrollView { content }
            .scrollBounceBehavior(.basedOnSize)
            .presentationDetents([.height(contentHeight)])
            .presentationDragIndicator(.visible)
            .presentationBackground(theme.color.surfaceSheet)
            .interactiveDismissDisabled(working)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.space.s3) {
            HStack {
                VStack(alignment: .leading, spacing: theme.space.s1) {
                    Text("Unpair \(entry.host.host() ?? "host")?").textRole(theme.type.body, theme.weight.bold)
                    Text(entry.agents.map(\.name).joined(separator: ", ")).textRole(theme.type.label)
                        .foregroundStyle(theme.color.textSecondary)
                }
                Spacer()
                GlassIconButton(title: "Close", systemImage: "xmark") { dismiss() }
            }
            Text("This phone forgets the host's device key and stops getting messages and calls from its agents. Chats stay on the host. To come back, pair again with a new link.")
                .textRole(theme.type.body)
            if let unreachable {
                Text("\(unreachable) Remove it from this phone anyway? The device stays listed on the host until you revoke it there.")
                    .textRole(theme.type.footnote).foregroundStyle(theme.color.danger)
                Button("Remove from this phone", role: .destructive) { unpair(localOnly: true) }
                    .buttonStyle(PanelActionStyle(destructive: true))
            } else {
                Button(working ? "Unpairing…" : "Unpair", role: .destructive) { unpair(localOnly: false) }
                    .buttonStyle(PanelActionStyle(destructive: true))
            }
            Button("Cancel") { dismiss() }.buttonStyle(PanelActionStyle(secondary: true))
        }
        .disabled(working)
        .foregroundStyle(theme.color.textPrimary).padding(theme.space.s4)
        .padding(.top, theme.space.s2)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0.rounded(.up) }
    }

    private func unpair(localOnly: Bool) {
        working = true
        Task {
            let failure = await ChatController.shared.unpair(host: entry.host, localOnly: localOnly)
            let remains = Pairings.shared.entries.contains { $0.host == entry.host }
            if remains, !localOnly, case .transport? = failure {
                unreachable = failure?.message
                working = false
                return
            }
            finished(remains ? failure?.message ?? "Could not unpair this host." : nil)
        }
    }
}
