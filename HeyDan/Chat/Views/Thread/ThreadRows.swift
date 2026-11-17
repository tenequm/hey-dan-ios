import SwiftUI
import HeyDanCore

extension AXID {
    static let conversationList = "chat.list"
    static let thread = "chat.thread"
    static let connection = "chat.connection"
    static let status = "chat.status"
    static func conversation(_ id: String) -> String { "chat.conversation.\(id)" }
    static func message(_ id: String) -> String { "chat.message.\(id)" }
    static func question(_ id: String) -> String { "chat.question.\(id)" }
}

struct StatusPill: View {
    let status: Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if status.state == .working || status.state == .waiting {
            HStack(spacing: 8) {
                PulseDot(color: Theme.think, still: reduceMotion).accessibilityHidden(true)
                if let label = status.label { Text(label) }
            }
            .font(Theme.sans(13))
            .foregroundStyle(Theme.muted)
            .padding(8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.label ?? status.state.rawValue)
            .accessibilityIdentifier(AXID.status)
        }
    }
}

struct MessageRow: View {
    let message: Message
    var outboxState: Outbox.State?
    var retry: (String) -> Void = { _ in }
    @State private var confirmsRetry = false

    var body: some View {
        if message.role == .user || message.role == .agent || message.role == .host {
            VStack(alignment: .leading, spacing: 10) {
                if message.role == .user {
                    Text(message.text).textSelection(.enabled)
                } else {
                    MessageBody(text: message.text)
                }
                ForEach(message.files, id: \.id) { AttachmentView(file: $0) }
                HStack {
                    if message.voice == .caller {
                        Label("From a call", systemImage: "mic")
                    } else if message.voice == .spoken {
                        Label("Spoken", systemImage: "speaker.wave.2")
                    }
                    ForEach(Array(message.reactions.enumerated()), id: \.offset) { _, reaction in
                        Text(reaction.emoji).accessibilityLabel("\(reaction.emoji), \(reaction.by.rawValue)")
                    }
                    if message.editedAt != nil { Text("Edited") }
                }
                .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                if message.role == .user { delivery }
            }
            .font(Theme.sans(16))
            .foregroundStyle(Theme.text)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == .user ? Theme.card : Theme.page, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AXID.message(message.id))
            .confirmationDialog("Send again? It may already have been received.", isPresented: $confirmsRetry, titleVisibility: .visible) {
                Button("Send again") { if let id = message.clientId { retry(id) } }
            }
        }
    }

    @ViewBuilder private var delivery: some View {
        if let outboxState, ![.stored, .routed, .reached, .failed, .outcomeUnknown].contains(outboxState) {
            Text(outboxLabel(outboxState)).font(Theme.sans(12)).foregroundStyle(Theme.muted)
        } else if let state = message.delivery {
            switch state {
            case .stored, .routed, .reached:
                Text(state.rawValue.capitalized).font(Theme.sans(12)).foregroundStyle(Theme.muted)
            case .failed, .outcomeUnknown:
                if let error = message.deliveryError { Text(error.message).foregroundStyle(Theme.error) }
                if let id = message.clientId {
                    Button("Send again") {
                        if state == .outcomeUnknown { confirmsRetry = true } else { retry(id) }
                    }
                }
            case .unknown: EmptyView()
            }
        }
    }

    private func outboxLabel(_ state: Outbox.State) -> String {
        switch state {
        case .queued: "Queued"
        case .uploading: "Uploading"
        case .sending: "Sending"
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
    var uploadProgress: [String: Double]
    var retry: (String) -> Void
    var discard: (String) -> Void
    @State private var confirmsRetry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.request.text).textSelection(.enabled)
            Text(label).font(Theme.sans(12)).foregroundStyle(Theme.muted)
            ForEach(entry.attachments, id: \.uploadKey) { attachment in
                Text(attachment.name)
                if entry.state == .uploading {
                    ProgressView(value: uploadProgress[attachment.uploadKey] ?? 0)
                }
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
        .accessibilityIdentifier("chat.outbox.\(entry.request.clientId)")
        .confirmationDialog("Send again? It may already have been received.", isPresented: $confirmsRetry, titleVisibility: .visible) {
            Button("Send again") { retry(entry.request.clientId) }
        }
    }

    private var label: String {
        switch entry.state {
        case .queued: "Queued"
        case .uploading: "Uploading"
        case .sending: "Sending"
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
