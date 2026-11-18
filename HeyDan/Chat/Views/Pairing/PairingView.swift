import HeyDanCore
import SwiftUI

extension EnvironmentValues {
    @Entry var pairingConfirmation: Binding<Pairings.Entry?> = .constant(nil)
}

struct PairingView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.pairingConfirmation) private var confirmation
    @State private var link = ""
    @State private var working = false
    @State private var message: String?
    var paired: Pairings.Entry? = nil

    private var host: String? { PairingLink(link, allowsLocalNetworking: true)?.baseURL.host() }
    private var failure: String? { message ?? Pairings.shared.error?.message }

    var body: some View {
        VStack(spacing: theme.space.s2) {
            ZStack {
                Text(paired == nil ? "Pair a host" : "Paired").textRole(theme.type.headline, theme.weight.semibold)
                HStack {
                    if isPresented { GlassIconButton(title: "Back", systemImage: "chevron.left") { dismiss() } }
                    Spacer()
                    if paired == nil {
                        GlassIconButton(title: "Confirm pairing", systemImage: "checkmark", action: submit)
                            .disabled(working || link.isEmpty)
                            .opacity(working || link.isEmpty ? 0.45 : 1)
                    }
                }
            }
            .frame(minHeight: theme.control.touchTarget + theme.space.s3)
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    VStack(alignment: .leading, spacing: theme.space.s2) {
                        if paired != nil {
                            Label("Paired", systemImage: "checkmark.circle")
                                .textRole(theme.type.label, theme.weight.bold).foregroundStyle(theme.color.statusDone)
                        }
                        Text(paired.map { "\($0.host.host() ?? "Host") is ready" } ?? "Pair this phone")
                            .textRole(theme.type.largeTitle, theme.weight.bold)
                        Text(paired == nil
                             ? "Send /pair to Dan, or run ncl devices pair on the host. Paste the link here. It works once and expires after 10 minutes."
                             : "This phone can now chat with the agents on this host. You can pair more hosts in Settings.")
                            .textRole(theme.type.body).foregroundStyle(theme.color.textSecondary)
                    }
                    .padding(.horizontal, theme.space.s2)
                    if let paired {
                        SettingsSection("Agents") {
                            ForEach(paired.agents, id: \.id) { agent in
                                SettingsRow(title: agent.name, icon: "person")
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text("Pairing link").padding(.horizontal, theme.space.s4)
                            HStack(spacing: theme.space.s3) {
                                Text("Link")
                                Text(link.isEmpty ? "https://host/app/pair#…" : host.map { "\($0)/app/pair#••••" } ?? "Link pasted")
                                    .foregroundStyle(link.isEmpty ? theme.color.placeholder : theme.color.textPrimary)
                                    .accessibilityIdentifier("pairing.link")
                                Spacer()
                                if !link.isEmpty {
                                    Button("Clear link", systemImage: "xmark.circle") {
                                        link = ""
                                        message = nil
                                    }
                                    .labelStyle(.iconOnly).disabled(working)
                                }
                            }
                            .textRole(theme.type.body)
                            .padding(theme.space.s4)
                            .background(theme.color.surfaceGrouped, in: RoundedRectangle(cornerRadius: theme.radius.field))
                            .overlay {
                                if failure != nil { RoundedRectangle(cornerRadius: theme.radius.field).strokeBorder(theme.color.danger) }
                            }
                            Text(failure ?? host.map { "Host: \($0)" } ?? "The host keeps its own keys. This phone gets a device key.")
                                .foregroundStyle(failure == nil ? theme.color.textSecondary : theme.color.danger)
                                .padding(.horizontal, theme.space.s4)
                        }
                        .textRole(theme.type.footnote).foregroundStyle(theme.color.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, theme.space.s4)
            }
            if paired != nil {
                Button("Open chats") {
                    ChatController.shared.closeConversation()
                    confirmation.wrappedValue = nil
                }
                .buttonStyle(PanelActionStyle())
            } else {
                PasteButton(payloadType: String.self) { @Sendable values in
                    Task { @MainActor in
                        guard let pasted = values.first else { return }
                        link = pasted
                        message = nil
                    }
                }
                .labelStyle(.titleAndIcon).buttonBorderShape(.capsule)
                .frame(maxWidth: .infinity, minHeight: theme.control.touchTarget + theme.space.s1)
                .background(theme.color.surfaceCard, in: Capsule())
                .accessibilityLabel("Paste from clipboard")
                .accessibilityIdentifier("pairing.paste").disabled(working)
                Button(action: submit) {
                    if working { ProgressView() }
                    else { Text(failure != nil ? "Try again" : host.map { "Pair with \($0)" } ?? "Pair") }
                }
                .buttonStyle(PanelActionStyle()).disabled(working || link.isEmpty)
                .accessibilityIdentifier("pairing.submit")
            }
        }
        .padding(.horizontal, theme.space.s4).padding(.bottom, theme.space.s2)
        .foregroundStyle(theme.color.textPrimary)
        .background(theme.color.surface.ignoresSafeArea())
        .interactiveDismissDisabled(working)
    }

    private func submit() {
        guard !working, !link.isEmpty else { return }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await Pairings.shared.pair(link)
                link = ""
                confirmation.wrappedValue = Pairings.shared.active
            } catch let error as AppError { message = error.message }
            catch { message = error.localizedDescription }
        }
    }
}

struct PanelActionStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    var destructive = false
    var secondary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.textRole(theme.type.body, theme.weight.medium)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: theme.control.touchTarget + theme.space.s1)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var ink: Color {
        if !enabled { return theme.color.textSecondary }
        if destructive { return theme.color.danger }
        return secondary ? theme.color.textPrimary : theme.color.onAccent
    }
    private var fill: Color {
        if !enabled { return theme.color.surfaceGrouped }
        if destructive { return theme.color.dangerSurface }
        return secondary ? theme.color.secondaryFill : theme.color.accent
    }
}
