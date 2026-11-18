import SwiftUI
import HeyDanCore

struct ThreadView: View {
    let conversation: Conversation
    @Environment(ChatController.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @State private var answeredQuestionID: String?
    private var live: Conversation { chat.conversations.first { $0.id == conversation.id } ?? conversation }

    var body: some View {
        ThreadContent(
            rows: chat.rows,
            status: chat.statuses[conversation.id],
            outboxStates: chat.outboxStates,
            hasMoreBefore: chat.hasMoreBefore,
            errorMessage: chat.error?.message,
            errorQuestionID: answeredQuestionID,
            active: scenePhase == .active && !CallController.shared.showsPairedCall,
            answer: { id, value in
                answeredQuestionID = id
                Task { await chat.answer(questionId: id, value: value) }
            },
            retry: { id in Task { await chat.retry(clientId: id) } },
            discard: { id in Task { await chat.discard(clientId: id) } },
            markRead: { order in Task { await chat.markRead(order: order) } },
            loadHistory: { await chat.loadHistory(before: $0) }
        )
        .safeAreaBar(edge: .bottom) {
            ComposerView { text, attachments in
                await chat.send(text: text, attachments: attachments)
            }
            .id(conversation.id)
        }
        .safeAreaBar(edge: .top) {
            if chat.features.contains("calls"), !live.canCall, let refusal = live.callRefusal {
                Text(refusal.message)
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("chat.call.refusal")
            }
        }
        .navigationTitle(conversation.agent.name)
        .toolbar { ThreadCallButton(conversation: conversation) }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

struct ThreadContent: View {
    let rows: [ThreadRow]
    var status: Status?
    var outboxStates: [String: Outbox.State] = [:]
    var hasMoreBefore = false
    var errorMessage: String?
    var errorQuestionID: String?
    var active = true
    var answer: (String, String) -> Void = { _, _ in }
    var retry: (String) -> Void = { _ in }
    var discard: (String) -> Void = { _ in }
    var markRead: (Int64) -> Void = { _ in }
    var loadHistory: (Int64) async -> Void = { _ in }
    @State private var visibleID: String?
    @State private var atBottom = false
    @State private var loadingHistory = false

    private var entities: [ThreadEntity] { rows.compactMap { if case .entity(let entity) = $0 { return entity }; return nil } }
    private var firstOrder: Int64? { entities.compactMap(\.order).min() }
    private var newestOrder: Int64? { entities.filter(readable).compactMap(\.order).max() }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if hasMoreBefore, let firstOrder {
                    Button("Load older messages") {
                        Task { await loadOlder(firstOrder) }
                    }
                    .disabled(loadingHistory)
                    .onAppear { Task { await loadOlder(firstOrder) } }
                }
                ForEach(rows, id: \.presentationID) { row in
                    switch row {
                    case .entity(.message(let message)):
                        MessageRow(message: message, outboxState: message.clientId.flatMap { outboxStates[$0] }, retry: retry)
                            .id(row.presentationID)
                    case .entity(.question(let question)):
                        QuestionCard(question: question, errorMessage: question.id == errorQuestionID ? errorMessage : nil) { answer(question.id, $0) }
                            .id(row.presentationID)
                    case .outbox(let entry):
                        OutboxRow(entry: entry, retry: retry, discard: discard)
                            .id(row.presentationID)
                    case .entity(.unknown): EmptyView()
                    }
                }
                if let status { StatusPill(status: status) }
            }
            .scrollTargetLayout()
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $visibleID)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 16
        } action: { _, bottom in
            atBottom = bottom
            readVisibleBottom()
        }
        .onChange(of: newestOrder) { readVisibleBottom() }
        .onChange(of: active) { readVisibleBottom() }
        .background(Theme.page)
        .accessibilityIdentifier(AXID.thread)
    }

    private func readVisibleBottom() {
        if active, atBottom, let newestOrder { markRead(newestOrder) }
    }

    private func loadOlder(_ order: Int64) async {
        guard !loadingHistory else { return }
        loadingHistory = true
        await loadHistory(order)
        loadingHistory = false
    }

    /// The rows a read counts: the reducer already dropped roles it cannot render, and only live questions count.
    private func readable(_ entity: ThreadEntity) -> Bool {
        switch entity {
        case .message: true
        case .question(let question): [.open, .answered, .expired].contains(question.state)
        case .unknown: false
        }
    }
}

private extension ThreadRow {
    var presentationID: String {
        switch self {
        case .entity(.message(let message)): return message.clientId.map { "client.\($0)" } ?? message.id
        case .entity(.question(let question)): return question.id
        case .outbox(let entry): return "client.\(entry.request.clientId)"
        case .entity(.unknown): return "unknown"
        }
    }
}
