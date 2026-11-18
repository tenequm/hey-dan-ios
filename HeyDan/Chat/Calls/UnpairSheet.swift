import SwiftUI

struct UnpairSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let entry: Pairings.Entry
    let finished: (String?) -> Void
    @State private var working = false

    var body: some View {
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
            Button(working ? "Unpairing…" : "Unpair", role: .destructive) {
                working = true
                Task {
                    await ChatController.shared.unpair(host: entry.host)
                    let remains = Pairings.shared.entries.contains { $0.host == entry.host }
                    finished(remains ? ChatController.shared.error?.message ?? "Could not unpair this host." : nil)
                }
            }
            .buttonStyle(PanelActionStyle(destructive: true))
            Button("Cancel") { dismiss() }.buttonStyle(PanelActionStyle(secondary: true))
        }
        .disabled(working).interactiveDismissDisabled(working)
        .foregroundStyle(theme.color.textPrimary).padding(theme.space.s4)
        .presentationSizing(.fitted).presentationDragIndicator(.visible).presentationBackground(theme.color.surfaceSheet)
    }
}
