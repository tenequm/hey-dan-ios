import SwiftUI
import HeyDanCore

struct ThreadView: View {
    @Environment(\.theme) private var theme
    let conversation: Conversation
    @Environment(ChatController.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @State private var answerFailure: (questionID: String, message: String)?
    @State private var agentStatus: AgentStatus?
    @State private var statusFailure: String?
    @State private var statusRequest = UUID()
    @State private var refresh = 0
    @State private var showsAgentSettings = false
    private var supportsStatus: Bool { chat.features.contains("agent-status") }
    private var live: Conversation { chat.conversation(conversation.id) ?? conversation }

    private var call: CallController { .shared }
    private var target: PairedCallTarget? {
        guard let host = chat.host, let device = chat.pairing?.deviceId else { return nil }
        return PairedCallTarget(host: host, deviceId: device, conversation: live)
    }

    private var callTarget: CallTarget? {
        guard let target, call.matches(target) else { return nil }
        return call.pairedCallTarget
    }

    var body: some View {
        let activeTarget = call.isCallActive ? callTarget : nil
        let attemptId = callTarget?.attemptId
        ThreadContent(
            rows: chat.rows,
            agentName: conversation.agent.name,
            compactedThrough: chat.compactedThrough[conversation.id],
            status: activeTarget == nil ? chat.statuses[conversation.id] : nil,
            showsCaptions: activeTarget != nil,
            outboxStates: chat.outboxStates,
            hasMoreBefore: chat.hasMoreBefore,
            errorMessage: answerFailure?.message,
            errorQuestionID: answerFailure?.questionID,
            active: scenePhase == .active,
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
            VStack(spacing: 0) {
                if let activeTarget {
                    ThreadCallBar(target: activeTarget)
                } else if attemptId != nil, let ending = call.endingNotice, let target {
                    let failed = CallController.isFailure(ending, liveSince: call.liveSince)
                    HStack {
                        Label(ending.message, systemImage: failed ? "exclamationmark.circle" : "phone.down")
                        Spacer()
                        Button("Call again") {
                            Task { _ = await call.start(target: CallTarget(paired: target, service: chat.service)) }
                        }
                        .disabled(!live.canCall || !chat.features.contains("calls"))
                    }
                    .textRole(theme.type.footnote, theme.weight.medium)
                    .foregroundStyle(failed ? theme.color.danger : theme.color.textSecondary)
                    .padding(.vertical, theme.space.s3).padding(.horizontal, theme.space.s3_5)
                    .background(failed ? theme.color.dangerSurface : theme.color.surfaceCard, in: RoundedRectangle(cornerRadius: theme.radius.l))
                    .overlay { RoundedRectangle(cornerRadius: theme.radius.l).strokeBorder(failed ? theme.color.dangerBorder : theme.color.border).allowsHitTesting(false) }
                    .padding(.horizontal, theme.space.s3).padding(.bottom, theme.space.s1_5)
                }
                // Keep the draft and its staged files alive across a call.
                ComposerView(features: chat.features, send: { text, attachments in
                    let sent = await chat.send(text: text, attachments: attachments)
                    if sent { call.dismissEndingNotice(attemptId: attemptId) }
                    return sent
                }, failure: chat.sendFailure, isInCall: activeTarget != nil,
                   agentStatus: supportsStatus ? agentStatus : nil,
                   openSettings: { showsAgentSettings = true },
                   compact: { _ = await compact() })
                .id(conversation.id)
            }
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
        .onDisappear { call.dismissEndingNotice(attemptId: attemptId) }
        .navigationTitle(conversation.agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if supportsStatus {
                    Menu {
                        Button("Agent settings", systemImage: "slider.horizontal.3") { showsAgentSettings = true }
                            .disabled(call.isCallActive)
                    } label: {
                        HStack(spacing: theme.space.s1) {
                            threadTitle
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }
                    .accessibilityLabel(conversation.agent.name)
                    .accessibilityValue(headerValue)
                    .accessibilityIdentifier("chat.thread.menu")
                } else { threadTitle }
            }
            ToolbarItemGroup(placement: .topBarTrailing) { ThreadCallButton(conversation: conversation) }
        }
        .onChange(of: call.isCallActive) { _, active in
            if active { showsAgentSettings = false }
        }
        .onChange(of: chat.statuses[conversation.id]) { previous, current in
            if let current, current.state == .idle,
               previous?.state != .idle || previous?.rev != current.rev { refresh += 1 }
        }
        .task(id: supportsStatus ? refresh : nil) {
            guard supportsStatus else { agentStatus = nil; statusFailure = nil; return }
            await loadStatus()
        }
        .sheet(isPresented: $showsAgentSettings) {
            if let agentStatus, supportsStatus {
                AgentSettingsSheet(status: agentStatus,
                    editable: chat.features.contains("agent-settings") && agentStatus.agent.canEdit,
                    statusFailure: statusFailure, save: saveSettings, compact: compact)
            } else {
                VStack(spacing: theme.space.s3) {
                    if let statusFailure {
                        Text(statusFailure)
                        Button("Retry") { refresh += 1 }
                    } else if supportsStatus { ProgressView("Loading agent settings") }
                    else { Text("Agent status is unavailable.") }
                    Button("Close") { showsAgentSettings = false }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .tint(theme.color.accentText)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
    private var headerValue: Text {
        if call.isCallActive, callTarget != nil {
            if let since = call.liveSince { return Text("On call, \(since, style: .timer)") }
            return Text("On call, 0:00")
        }
        return Text(chat.host?.host() ?? "")
    }

    private var threadTitle: some View {
        VStack(spacing: 0) {
            Text(conversation.agent.name).textRole(theme.type.headline, theme.weight.semibold)
            if call.isCallActive, callTarget != nil {
                HStack(spacing: 0) {
                    Text("On call · ")
                    CallElapsed(since: call.liveSince)
                }
                .textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
            } else if let host = chat.host?.host() {
                Text(host).textRole(theme.type.caption).foregroundStyle(theme.color.textSecondary)
            }
        }
        .lineLimit(1)
    }

    private func loadStatus() async {
        let request = UUID()
        statusRequest = request
        statusFailure = nil
        do {
            let response = try await chat.service.agentStatus(conversationId: conversation.id)
            guard !Task.isCancelled, statusRequest == request else { return }
            chat.observeContext(response.status.session, conversationID: conversation.id)
            agentStatus = response.status
        } catch {
            guard !Task.isCancelled, statusRequest == request else { return }
            statusFailure = error.message
        }
    }

    private func saveSettings(_ request: AgentSettingsRequest) async throws(AppError) {
        guard !call.isCallActive else { throw .callActive }
        guard chat.openConversationId == conversation.id else { throw .transport(.cancelled) }
        guard supportsStatus,
              chat.features.contains("agent-settings"), agentStatus?.agent.canEdit == true else { throw .limit("Agent settings are read-only.") }
        let generation = chat.generation
        let response = try await chat.service.updateSettings(agentId: conversation.agent.id, request: request)
        guard generation == chat.generation, chat.openConversationId == conversation.id else { return }
        statusRequest = UUID()
        agentStatus?.agent = response.agent
    }

    private func compact() async -> Bool {
        guard chat.openConversationId == conversation.id, agentStatus?.agent.canEdit == true else { return false }
        return await chat.send(text: "/compact")
    }

}

struct ThreadContent: View {
    @Environment(\.theme) private var theme
    let rows: [ThreadRow]
    var agentName: String?
    var compactedThrough: Int64?
    var status: Status?
    var showsCaptions = false
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
                        MessageRow(message: message, compacted: compactedThrough.map { message.order <= $0 } ?? false, outboxState: message.clientId.flatMap { outboxStates[$0] }, retry: retry, discard: discard)
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
                if showsCaptions { LiveCaptionRows(rows: rows) }
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
