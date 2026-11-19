import SwiftUI
import HeyDanCore

struct ThreadView: View {
    @Environment(\.theme) private var theme
    let conversation: Conversation
    @Environment(ChatController.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @State private var answerFailure: (questionID: String, message: String)?
    private var live: Conversation { chat.conversation(conversation.id) ?? conversation }

    var body: some View {
        ThreadContent(
            rows: chat.rows,
            agentName: conversation.agent.name,
            status: chat.statuses[conversation.id],
            outboxStates: chat.outboxStates,
            hasMoreBefore: chat.hasMoreBefore,
            errorMessage: answerFailure?.message,
            errorQuestionID: answerFailure?.questionID,
            active: scenePhase == .active && !CallController.shared.showsPairedCall,
            answer: { id, value in
                answerFailure = nil
                Task { answerFailure = await chat.answer(questionId: id, value: value).map { (id, $0) } }
            },
            retry: { id in Task { await chat.retry(clientId: id) } },
            discard: { id in Task { await chat.discard(clientId: id) } },
            markRead: { order in Task { await chat.markRead(order: order) } },
            loadHistory: { await chat.loadHistory(before: $0) }
        )
        .sensoryFeedback(.error, trigger: chat.outbox.entries) { previous, current in
            current.contains { entry in
                entry.conversationId == conversation.id && entry.state.canSendAgain &&
                    previous.contains { $0.request.clientId == entry.request.clientId && !$0.state.canSendAgain }
            }
        }
        .safeAreaBar(edge: .bottom) {
            ComposerView(send: { text, attachments in
                await chat.send(text: text, attachments: attachments)
            }, failure: chat.sendFailure)
            .id(conversation.id)
        }
        .safeAreaBar(edge: .top) {
            if chat.features.contains("calls"), !live.canCall, let refusal = live.callRefusal {
                Text(refusal.message)
                    .textRole(theme.type.label)
                    .foregroundStyle(theme.color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, theme.space.s1_5)
                    .accessibilityIdentifier("chat.call.refusal")
            }
        }
        .navigationTitle(conversation.agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(conversation.agent.name).textRole(theme.type.headline, theme.weight.semibold)
                    if let host = chat.host?.host() {
                        Text(host).textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
                    }
                }
                .lineLimit(1)
            }
            ToolbarItemGroup(placement: .topBarTrailing) { ThreadCallButton(conversation: conversation) }
        }
        .tint(theme.color.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

struct ThreadContent: View {
    @Environment(\.theme) private var theme
    let rows: [ThreadRow]
    var agentName: String?
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
            LazyVStack(spacing: theme.space.s4) {
                if hasMoreBefore, let firstOrder {
                    Button {
                        Task { await loadOlder(firstOrder) }
                    } label: {
                        HistoryLoader(loading: loadingHistory)
                    }
                    .accessibilityLabel("Load older messages")
                    .disabled(loadingHistory)
                    .onAppear { Task { await loadOlder(firstOrder) } }
                }
                ForEach(rows, id: \.presentationID) { row in
                    switch row {
                    case .entity(.message(let message)):
                        MessageRow(message: message, outboxState: message.clientId.flatMap { outboxStates[$0] }, retry: retry, discard: discard)
                            .id(row.presentationID)
                    case .entity(.question(let question)):
                        QuestionCard(agentName: agentName, question: question, errorMessage: question.id == errorQuestionID ? errorMessage : nil) { answer(question.id, $0) }
                            .id(row.presentationID)
                    case .outbox(let entry):
                        OutboxRow(entry: entry, retry: retry, discard: discard)
                            .id(row.presentationID)
                    case .entity(.unknown): EmptyView()
                    }
                }
                if let status { StatusPill(status: status, style: .capsule) }
            }
            .scrollTargetLayout()
            .padding(theme.space.s4)
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
        .background(theme.color.surface)
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


struct HistoryLoader: View {
    @Environment(\.theme) private var theme
    let loading: Bool

    var body: some View {
        HStack(spacing: theme.space.s2) {
            if loading { ProgressView().controlSize(.small) }
            Text(loading ? "Loading earlier messages" : "Load older messages")
        }
        .textRole(theme.type.label)
        .foregroundStyle(theme.color.textSecondary)
        .padding(.vertical, theme.space.s3)
    }
}
