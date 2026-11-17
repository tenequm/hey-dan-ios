import SwiftUI
import HeyDanCore

struct ThreadView: View {
    let conversation: Conversation
    @Environment(ChatController.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsCall = false
    @State private var answeredQuestionID: String?

    var body: some View {
        ThreadContent(
            rows: chat.rows,
            status: chat.statuses[conversation.id],
            outboxStates: chat.outboxStates,
            uploadProgress: chat.uploadProgress,
            hasMoreBefore: chat.hasMoreBefore,
            errorMessage: chat.error?.message,
            errorQuestionID: answeredQuestionID,
            active: scenePhase == .active && !showsCall,
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
        .navigationTitle(conversation.agent.name)
        .toolbar { Button("Call") { showsCall = true }.disabled(!conversation.canCall) }
        .fullScreenCover(isPresented: $showsCall) { ContentView() }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

struct ThreadContent: View {
    let rows: [ThreadRow]
    var status: Status?
    var outboxStates: [String: Outbox.State] = [:]
    var uploadProgress: [String: Double] = [:]
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
    private var firstOrder: Int64? { entities.compactMap { order($0) }.min() }
    private var newestOrder: Int64? { entities.compactMap(item).compactMap { order($0.entity) }.max() }

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
                        OutboxRow(entry: entry, uploadProgress: uploadProgress, retry: retry, discard: discard)
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
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 16
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

    private func order(_ entity: ThreadEntity) -> Int64? {
        switch entity {
        case .message(let message): return message.order
        case .question(let question): return question.order
        case .unknown: return nil
        }
    }

    private func item(_ entity: ThreadEntity) -> (id: String, entity: ThreadEntity)? {
        switch entity {
        case .message(let message):
            guard message.role == .user || message.role == .agent || message.role == .host else { return nil }
            return (message.id, entity)
        case .question(let question):
            guard [.open, .answered, .expired].contains(question.state) else { return nil }
            return (question.id, entity)
        case .unknown: return nil
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
