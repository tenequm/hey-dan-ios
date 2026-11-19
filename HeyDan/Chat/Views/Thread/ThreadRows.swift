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
                if style == .capsule, status.state == .working, status.at > 0 {
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
    var discard: (String) -> Void = { _ in }
    @State private var confirmsRetry = false

    private var visibleCard: Card? {
        guard message.role == .agent, let card = message.card,
              card.title?.isEmpty == false || card.description?.isEmpty == false ||
              !card.parts.isEmpty || card.actions.contains(where: { $0.webURL != nil }) else { return nil }
        return card
    }

    var body: some View {
        // Not only a role filter: without this branch, a sent message that takes over its outbox row's ForEach id
        // never reaches UI checks with its own identifier and label (ChatComposerChecks.testTextSend).
        if message.role == .user || message.role == .agent || message.role == .host {
            let outgoing = message.role == .user
            VStack(alignment: outgoing ? .trailing : .leading, spacing: theme.space.s1_5) {
                if outgoing {
                    if !message.text.isEmpty && !message.files.contains(where: { $0.kind == .audio && ($0.transcript?.text == message.text || $0.transcript == nil) }) {
                        Text(message.text).textSelection(.enabled).modifier(UserBubble())
                    }
                } else if let card = visibleCard {
                    RichCard(card: card)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(AXID.card(message.id))
                } else if !message.text.isEmpty {
                    MessageBody(text: message.text)
                }
                ForEach(message.files, id: \.id) { file in
                    if outgoing, file.kind == .audio {
                        VoiceMessageView(file: file, durationMs: file.durationMs, messageText: message.text)
                            .modifier(UserBubble())
                    } else {
                        AttachmentView(file: file)
                    }
                }
                HStack(spacing: theme.space.s2) {
                    if message.voice == .caller || message.voice == .spoken {
                        Label("Spoken", systemImage: message.voice == .caller ? "mic" : "speaker.wave.2")
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
            .accessibilityElement(children: visibleCard != nil || message.files.contains(where: { $0.kind == .audio }) ? .contain : .combine)
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
                    HStack {
                        if outboxState?.canSendAgain == true {
                            Button("Send again") {
                                if state == .outcomeUnknown { confirmsRetry = true } else { retry(id) }
                            }
                        }
                        if outboxState != nil {
                            Button("Discard", role: .destructive) { discard(id) }
                        }
                    }
                }
            case .unknown: EmptyView()
            }
        }
    }
}

struct QuestionCard: View {
    @Environment(\.theme) private var theme
    var agentName: String? = nil
    let question: Question
    var errorMessage: String?
    var answer: (String) -> Void = { _ in }

    var body: some View {
        let answered = question.state == .answered
        VStack(alignment: .leading, spacing: theme.space.s2_5) {
            HStack(spacing: theme.space.s1_5) {
                if answered { Image(systemName: "checkmark.circle").foregroundStyle(theme.color.statusDone) }
                Text(answered ? "Answered" : [agentName, "needs input"].compactMap { $0 }.joined(separator: " "))
                    .textCase(.uppercase).tracking(1)
            }
            .textRole(theme.type.caption, theme.weight.bold).foregroundStyle(theme.color.textSecondary)
            Text(question.title).textRole(answered ? theme.type.footnote : theme.type.headline, answered ? theme.weight.regular : theme.weight.bold)
            if !question.text.isEmpty { MessageBody(text: question.text) }
            if answered, let chosen = question.answer {
                Text(question.options.first { $0.value == chosen.value }?.selectedLabel ?? chosen.label)
                    .textRole(theme.type.footnote, theme.weight.medium)
                    .padding(.leading, theme.space.s3)
                    .overlay(alignment: .leading) { Rectangle().fill(theme.color.statusDone).frame(width: theme.space.s0_5) }
                    .accessibilityIdentifier("chat.answer.\(question.id)")
            } else {
                ForEach(question.options, id: \.value) { option in
                    optionButton(option).disabled(question.state != .open)
                }
                if question.state == .expired { Text("Expired").foregroundStyle(theme.color.textSecondary) }
                if let errorMessage { Text(errorMessage).foregroundStyle(theme.color.danger) }
            }
        }
        .textRole(theme.type.body)
        .padding(theme.space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color.surfaceCard, in: RoundedRectangle(cornerRadius: theme.radius.bubble))
        .overlay { RoundedRectangle(cornerRadius: theme.radius.bubble).strokeBorder(theme.color.border) }
        .foregroundStyle(theme.color.textPrimary)
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

    private func optionButton(_ option: QuestionOption) -> some View {
        let primary = option.style == "primary"
        let shape = RoundedRectangle(cornerRadius: theme.radius.l)
        return Button(role: option.style == "danger" ? .destructive : nil) { answer(option.value) } label: {
            Text(option.label).textRole(theme.type.footnote, theme.weight.bold)
                .foregroundStyle(option.style == "danger" ? theme.color.danger : theme.color.textPrimary)
                .padding(.horizontal, theme.space.s3_5).padding(.vertical, theme.space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(primary ? theme.color.accentSoft : theme.color.surfaceInput, in: shape)
                .overlay { shape.strokeBorder(primary ? theme.color.accent : theme.color.border) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

struct OutboxRow: View {
    @Environment(\.theme) private var theme
    let entry: Outbox.Entry
    var retry: (String) -> Void
    var discard: (String) -> Void
    @State private var confirmsRetry = false

    var body: some View {
        VStack(alignment: .trailing, spacing: theme.space.s1_5) {
            if !entry.request.text.isEmpty { Text(entry.request.text).textSelection(.enabled).modifier(UserBubble()) }
            ForEach(entry.attachments, id: \.uploadKey) { attachment in
                if let duration = attachment.durationMs {
                    VoiceMessageView(durationMs: duration).modifier(UserBubble())
                } else {
                    Text(attachment.name)
                }
            }
            if let error = entry.lastServerError { Text(error.message).foregroundStyle(theme.color.danger) }
            HStack(spacing: theme.space.s1) {
                Label(entry.state.label, systemImage: entry.state == .failed ? "exclamationmark.circle" : "clock")
                    .foregroundStyle(entry.state == .failed ? theme.color.danger : theme.color.textSecondary)
                if entry.state.canSendAgain {
                    Text("·").foregroundStyle(theme.color.textTertiary)
                    Button("Retry") {
                        if entry.state == .outcomeUnknown { confirmsRetry = true }
                        else { retry(entry.request.clientId) }
                    }
                    .foregroundStyle(theme.color.accentText)
                    .textRole(theme.type.caption, theme.weight.bold)
                    Button("Discard", role: .destructive) { discard(entry.request.clientId) }
                }
            }
            .textRole(theme.type.caption)
            // A waiting entry can be a host that keeps failing it: Discard lets the conversation's later sends go.
            if entry.state == .held || entry.state == .waiting {
                Button("Discard", role: .destructive) { discard(entry.request.clientId) }
            }
        }
        .textRole(theme.type.body).foregroundStyle(theme.color.textPrimary)
        .tint(theme.color.accentText)
        .padding(.leading, theme.space.s10)
        .frame(maxWidth: .infinity, alignment: .trailing)
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
