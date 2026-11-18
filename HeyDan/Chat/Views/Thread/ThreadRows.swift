import SwiftUI
import HeyDanCore

extension AXID {
    static let thread = "chat.thread"
    static let status = "chat.status"
    static func conversation(_ id: String) -> String { "chat.conversation.\(id)" }
    static func message(_ id: String) -> String { "chat.message.\(id)" }
    static func question(_ id: String) -> String { "chat.question.\(id)" }
}

struct StatusPill: View {
    enum Style { case inline, capsule }
    let status: Status
    var style: Style = .inline
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if status.state == .working || status.state == .waiting {
            let ink = status.state == .working ? theme.color.statusWorking : theme.color.statusInput
            HStack(spacing: theme.space.s2) {
                if status.state == .working && !reduceMotion {
                    ProgressView().controlSize(.small).tint(ink)
                } else {
                    Image(systemName: status.state == .working ? "circle.dashed" : "questionmark.bubble").foregroundStyle(ink)
                }
                Text(status.label ?? status.state.rawValue.capitalized)
                if style == .capsule, status.state == .working {
                    Text(Date(timeIntervalSince1970: Double(status.at) / 1000), style: .timer)
                        .monospacedDigit().fixedSize().foregroundStyle(theme.color.textSecondary)
                }
            }
            .textRole(theme.type.label, theme.weight.medium)
            .foregroundStyle(style == .inline ? ink : theme.color.textPrimary)
            .padding(.horizontal, style == .inline ? 0 : theme.space.s4)
            .frame(minHeight: style == .inline ? nil : theme.control.touchTarget)
            .background { if style == .capsule { Capsule().fill(theme.color.glass).strokeBorder(theme.color.composerBorder) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.label ?? status.state.rawValue)
            .accessibilityIdentifier(AXID.status)
        }
    }
}

private struct UserBubble: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.vertical, theme.space.s2_5)
            .padding(.horizontal, theme.space.s3_5)
            .background(theme.color.userBubble, in: RoundedRectangle(cornerRadius: theme.radius.bubble))
    }
}

struct MessageRow: View {
    @Environment(\.theme) private var theme
    let message: Message
    var outboxState: Outbox.State?
    var retry: (String) -> Void = { _ in }
    @State private var confirmsRetry = false

    var body: some View {
        // Not only a role filter: without this branch, a sent message that takes over its outbox row's ForEach id
        // never reaches UI checks with its own identifier and label (ChatComposerChecks.testTextSend).
        if message.role == .user || message.role == .agent || message.role == .host {
            let outgoing = message.role == .user
            VStack(alignment: outgoing ? .trailing : .leading, spacing: theme.space.s1_5) {
                if outgoing {
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled).modifier(UserBubble())
                    }
                } else if !message.text.isEmpty {
                    MessageBody(text: message.text)
                }
                ForEach(message.files, id: \.id) { AttachmentView(file: $0) }
                HStack(spacing: theme.space.s2) {
                    if message.voice == .caller {
                        Label("From a call", systemImage: "mic")
                    } else if message.voice == .spoken {
                        Label("Spoken", systemImage: "speaker.wave.2")
                    }
                    ForEach(Array(message.reactions.enumerated()), id: \.offset) { _, reaction in
                        Text(reaction.emoji).accessibilityLabel("\(reaction.emoji), \(reaction.by.rawValue)")
                    }
                    if message.editedAt != nil { Text("Edited") }
                    if !outgoing {
                        Text(Date(timeIntervalSince1970: Double(message.createdAt) / 1000), style: .time)
                        if !message.text.isEmpty {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                .textRole(theme.type.caption).foregroundStyle(theme.color.textTertiary)
                if outgoing { delivery }
            }
            .textRole(theme.type.body)
            .foregroundStyle(theme.color.textPrimary)
            .padding(.leading, outgoing ? theme.space.s10 : 0)
            .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AXID.message(message.id))
            .confirmationDialog("Send again? It may already have been received.", isPresented: $confirmsRetry, titleVisibility: .visible) {
                Button("Send again") { if let id = message.clientId { retry(id) } }
            }
        }
    }

    @ViewBuilder private var delivery: some View {
        if let outboxState, ![.stored, .routed, .reached, .failed, .outcomeUnknown].contains(outboxState) {
            Text(outboxState.label).textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
        } else if let state = message.delivery {
            switch state {
            case .stored, .routed, .reached:
                Text(state.rawValue.capitalized).textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
            case .failed, .outcomeUnknown:
                if let error = message.deliveryError { Text(error.message).foregroundStyle(theme.color.danger) }
                if let id = message.clientId {
                    Button("Send again") {
                        if state == .outcomeUnknown { confirmsRetry = true } else { retry(id) }
                    }
                }
            case .unknown: EmptyView()
            }
        }
    }
}

struct QuestionCard: View {
    let question: Question
    var errorMessage: String?
    var answer: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.title).font(Theme.sans(18, .semibold))
            MessageBody(text: question.text)
            if question.state == .answered, let chosen = question.answer {
                Text(question.options.first { $0.value == chosen.value }?.selectedLabel ?? chosen.label)
                    .accessibilityIdentifier("chat.answer.\(question.id)")
            } else {
                ForEach(question.options, id: \.value) { option in
                    optionButton(option).disabled(question.state != .open)
                }
                if question.state == .expired { Text("Expired").foregroundStyle(Theme.muted) }
                if let errorMessage { Text(errorMessage).foregroundStyle(Theme.error) }
            }
        }
        .font(Theme.sans(16))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXID.question(question.id))
        .accessibilityActions {
            if question.state == .open {
                ForEach(question.options, id: \.value) { option in
                    Button(option.label) { answer(option.value) }
                }
            }
        }
    }

    @ViewBuilder private func optionButton(_ option: QuestionOption) -> some View {
        if option.style == "primary" {
            Button(option.label) { answer(option.value) }.buttonStyle(.borderedProminent)
        } else {
            Button(option.label, role: option.style == "danger" ? .destructive : nil) { answer(option.value) }
                .buttonStyle(.bordered)
        }
    }
}

struct OutboxRow: View {
    let entry: Outbox.Entry
    var retry: (String) -> Void
    var discard: (String) -> Void
    @State private var confirmsRetry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.request.text).textSelection(.enabled)
            Text(entry.state.label).font(Theme.sans(12)).foregroundStyle(Theme.muted)
            ForEach(entry.attachments, id: \.uploadKey) { attachment in
                Text(attachment.name)
            }
            if let error = entry.lastServerError { Text(error.message).foregroundStyle(Theme.error) }
            if entry.state == .failed || entry.state == .outcomeUnknown {
                Button("Send again") {
                    if entry.state == .outcomeUnknown { confirmsRetry = true }
                    else { retry(entry.request.clientId) }
                }
            }
            if entry.state == .held { Button("Discard", role: .destructive) { discard(entry.request.clientId) } }
        }
        .font(Theme.sans(16)).foregroundStyle(Theme.text)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .confirmationDialog("Send again? It may already have been received.", isPresented: $confirmsRetry, titleVisibility: .visible) {
            Button("Send again") { retry(entry.request.clientId) }
        }
    }
}

private extension Outbox.State {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .waiting: "Waiting to retry"
        case .held: "Held"
        case .stored: "Stored"
        case .routed: "Routed"
        case .reached: "Reached"
        case .failed: "Failed"
        case .outcomeUnknown: "Outcome unknown"
        }
    }
}
