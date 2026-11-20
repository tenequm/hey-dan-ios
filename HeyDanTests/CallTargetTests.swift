import AVFAudio
import CryptoKit
import Foundation
import HeyDanCore
import Intents
import XCTest
import Security
import Synchronization
@testable import HeyDan

private final class FixtureBundle {}

@MainActor final class CallTargetTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: FixtureBundle.self).url(forResource: "app-contract.fixtures", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(object[name]))
    }

    private let conversation = Conversation(kind: .conversation, id: "conv_taylor01", seq: 1,
        agent: Agent(id: "ag_taylor", name: "Taylor"), unread: 0, readOrder: 0, canCall: true, createdAt: 0)

    func testDebugCallsRequireExactlyTheConfiguredAgent() throws {
        func entry(_ agents: [Agent]) -> Pairings.Entry {
            Pairings.Entry(host: URL(string: "https://example.com")!,
                pairing: PairResponse(deviceId: "test", userName: "Tester", agents: agents, protocol: 1, serverTime: 0),
                features: ["calls"])
        }
        let agent = conversation.agent
        XCTAssertEqual(try IntentCall.testAgent(in: entry([agent]), expected: "taylor"), agent)
        XCTAssertThrowsError(try IntentCall.testAgent(in: entry([]), expected: agent.name))
        XCTAssertThrowsError(try IntentCall.testAgent(in: entry([agent, agent]), expected: agent.name))
        XCTAssertThrowsError(try IntentCall.testAgent(in: entry([agent]), expected: "Other"))
        XCTAssertThrowsError(try IntentCall.testAgent(in: entry([agent]), expected: nil))
    }

    func testRecentsUsesOnlyOneConcreteAgentHandle() {
        let host = URL(string: "https://example.invalid")!
        let target = PairedCallTarget(host: host, deviceId: "fixture", conversation: conversation)
        func intent(_ handles: [String]) -> INStartCallIntent {
            let people = handles.map {
                INPerson(personHandle: INPersonHandle(value: $0, type: .unknown), nameComponents: nil,
                    displayName: conversation.agent.name, image: nil, contactIdentifier: nil, customIdentifier: nil)
            }
            return INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
                destinationType: .redial, contacts: people, callCapability: .audioCall)
        }
        XCTAssertEqual(IntentCall.redialAgent(in: intent([target.agentHandle.uuidString])),
                       PairedAgentID.make(host: host, agentId: conversation.agent.id))
        XCTAssertNil(IntentCall.redialAgent(in: intent([conversation.agent.name])))
        XCTAssertNil(IntentCall.redialAgent(in: intent([AgentEntity.defaultID.uuidString])))
        XCTAssertNil(IntentCall.redialAgent(in: intent([target.agentHandle.uuidString, UUID().uuidString])))
        XCTAssertNil(IntentCall.redialAgent(in: intent([])))
    }

    func testLegacyCleanupDeletesBackupsAndPreservesUnrelatedAccounts() {
        let service = "test.legacy." + UUID().uuidString
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        defer { SecItemDelete(base as CFDictionary) }
        let removed = ["call-link", "voice-lines", "voice-lines-unreadable-1", "voice-lines-unreadable-2"]
        for account in removed + ["keep"] {
            var item = base
            item[kSecAttrAccount as String] = account
            item[kSecValueData as String] = Data([1])
            XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        }
        XCTAssertTrue(HeyDanApp.removeLegacyLinks(service: service))
        XCTAssertTrue(HeyDanApp.removeLegacyLinks(service: service))
        for account in removed + ["keep"] {
            var item = base
            item[kSecAttrAccount as String] = account
            XCTAssertEqual(SecItemCopyMatching(item as CFDictionary, nil), account == "keep" ? errSecSuccess : errSecItemNotFound)
        }
    }

    func testLaterTurnUsesItsOwnThreadOrderEvenWhenTheWordsRepeat() {
        let now = Date(timeIntervalSince1970: 100)
        for interim in ["other one", "No, the"] {
            var transcript = Transcript()
            transcript.caption(segment: "one", text: "No, the other one", isFinal: true, fromCaller: true, at: now)
            transcript.apply(.status(.init(turn: 1, status: .sent, text: "No, the other one")), at: now)
            var message = Message(kind: .message, id: "one", conversationId: conversation.id, order: 8, seq: 10,
                                  role: .user, text: "No, the other one.", files: [], reactions: [], voice: .caller, createdAt: 500_000)
            let first = transcript.lines[0].id
            transcript.caption(segment: "two", text: interim, isFinal: false, fromCaller: true, at: now)
            let orders: [Int: Int64] = [first: 7, transcript.lines[1].id: 8]
            func visible() -> [String] { transcript.liveCaptions(in: [.entity(.message(message))], after: orders).map(\.text) }
            XCTAssertEqual(visible(), [interim])
            let final = interim + " please"
            transcript.caption(segment: "two", text: final, isFinal: true, fromCaller: true, at: now)
            message.order = 9
            XCTAssertEqual(visible(), [final])
            message.text = final
            message.voice = .spoken
            XCTAssertEqual(visible(), [final])
            message.voice = .caller
            message.createdAt = 1
            XCTAssertEqual(visible(), [])
        }
    }

    func testAllPiecesOfTheOpenReplyYieldToTheirMatchingMessage() {
        var transcript = Transcript()
        transcript.apply(ReplyInfo(reply: 1), at: .now)
        transcript.caption(segment: "one", text: "All set", isFinal: true, fromCaller: false, at: .now)
        transcript.caption(segment: "two", text: "See you", isFinal: true, fromCaller: false, at: .now)
        let orders = Dictionary(uniqueKeysWithValues: transcript.lines.map { ($0.id, Int64(5)) })
        var message = Message(kind: .message, id: "one", conversationId: conversation.id, order: 6, seq: 15,
                              role: .agent, text: "An unrelated reply", files: [], reactions: [], createdAt: 0)
        func visible() -> [String] { transcript.liveCaptions(in: [.entity(.message(message))], after: orders).map(\.text) }
        XCTAssertEqual(visible(), ["All set", "See you"])
        message.text = "All set!"
        XCTAssertEqual(visible(), ["See you"])
        message.text = "All set! See you."
        XCTAssertEqual(visible(), [])
    }

    func testDeliveryMarkerLastsUntilTheNextTurn() {
        for (event, expected) in [(TurnMessage.unheard, "Not heard"),
                                  (.dropped(.init(.asleep, text: "Ready")), "Not heard"),
                                  (.status(.init(turn: 1, status: .lost, reason: .timeout, text: "Ready")), "Delivery not confirmed")] {
            var transcript = Transcript()
            transcript.caption(segment: "one", text: "Ready", isFinal: true, fromCaller: true, at: .now)
            transcript.apply(event, at: .now)
            XCTAssertEqual(transcript.deliveryMarker, expected)
            transcript.caption(segment: "two", text: "Again", isFinal: false, fromCaller: true, at: .now)
            XCTAssertNil(transcript.deliveryMarker)
        }
    }

    func testJoiningBecomesListeningAndSystemJoinedOnlyDuringTheListeningCue() throws {
        let date = Date(timeIntervalSince1970: 10)
        let joining = CallController.ConnectionMilestone.joining.transition(at: date)
        XCTAssertEqual(joining.phase, .joining)
        XCTAssertEqual(joining.event, .conversationStartedConnecting(date))

        let events = Mutex<[CallController.ConnectionMilestone]>([])
        let playback = ListeningCuePlayback { event in events.withLock { $0.append(event) } }
        for activity in [VoiceProtocol.AgentActivity.listening, .thinking, .speaking] {
            XCTAssertNil(CallController.ConnectionMilestone.joining.workerUpdate(activity))
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        func render(_ hz: Double, milliseconds: Int, to renderer: ListeningCueRenderer) throws {
            let frames = AVAudioFrameCount(milliseconds * 48)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            pcm.frameLength = frames
            let samples = try XCTUnwrap(pcm.floatChannelData?[0])
            for i in 0 ..< Int(frames) { samples[i] = Float(0.15 * sin(2 * .pi * hz * Double(i) / 48_000)) }
            renderer.render(pcmBuffer: pcm)
        }

        for renderer in [playback.output, playback.track] {
            try render(0, milliseconds: 100, to: renderer)
            try render(784, milliseconds: 90, to: renderer)
            try render(523, milliseconds: 140, to: renderer) // Discard shares the opening note.
            try render(1175, milliseconds: 80, to: renderer)
            try render(1568, milliseconds: 110, to: renderer)
            try render(784, milliseconds: 110, to: renderer)
        }
        XCTAssertTrue(events.withLock { $0.isEmpty })
        try render(1175, milliseconds: 10, to: playback.track)
        XCTAssertTrue(events.withLock { $0.isEmpty }, "Decoded audio has yet to play.")
        try render(1175, milliseconds: 10, to: playback.output)
        let event = try XCTUnwrap(events.withLock { $0.first }).transition(at: date)
        XCTAssertEqual(event.phase, .live(.listening))
        XCTAssertEqual(event.event, .conversationConnected(date))
        for renderer in [playback.track, playback.output] {
            try render(784, milliseconds: 110, to: renderer)
            try render(1175, milliseconds: 130, to: renderer)
        }
        XCTAssertEqual(events.withLock { $0.count }, 1)
    }

    func testCallSetupLabelsAndBundledTone() throws {
        XCTAssertEqual(CallController.Phase.connecting.callBarLabel, "Connecting...")
        XCTAssertEqual(CallController.Phase.joining.callBarLabel, "Joining...")
        XCTAssertEqual(CallController.Phase.live(.listening).callBarLabel, "Listening")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Connecting", withExtension: "wav"))
        let tone = try AVAudioPlayer(contentsOf: url)
        XCTAssertGreaterThan(tone.duration, 0)
        XCTAssertLessThan(tone.duration, 0.25)
    }

    func testCallEndingFeedbackUsesConnectionHistory() {
        let remote = CallController.Ending(cause: .remote, message: "Call ended.")
        let live = CallController.Phase.live(.speaking)
        XCTAssertEqual(HeyDanApp.callFeedback(from: .connecting, to: live, liveSince: .now), .success)
        XCTAssertTrue(CallController.Phase.joining.isStarting)
        XCTAssertFalse(live.isStarting)
        XCTAssertNil(HeyDanApp.callFeedback(from: .connecting, to: .joining, liveSince: nil))
        XCTAssertEqual(HeyDanApp.callFeedback(from: .joining, to: live, liveSince: .now), .success)
        XCTAssertEqual(HeyDanApp.callFeedback(from: live, to: .ended(remote), liveSince: .now), .impact(weight: .light))
        XCTAssertEqual(HeyDanApp.callFeedback(from: .connecting, to: .ended(.byCaller), liveSince: nil), .impact(weight: .light))
        XCTAssertEqual(HeyDanApp.callFeedback(from: .connecting, to: .ended(.failure(.microphoneDenied)), liveSince: nil), .error)
    }

    func testAgentRefreshReplacesSnapshotAndIgnoresAnOldDevice() async throws {
        let account = "test-agents-" + UUID().uuidString
        defer { try? IdentityKeychain.remove(account: account) }
        let pairings = Pairings(account: account, publishes: false)
        while pairings.state == .unreadable { await Task.yield() }
        let host = URL(string: "https://example.com")!
        let old = Agent(id: "former", name: "Former")
        try pairings.add(PairResponse(deviceId: "current", userName: "Tester", agents: [old], protocol: 1, serverTime: 0),
                         host: host, features: ["calls"])
        pairings.refreshAgents([conversation, conversation], host: host, deviceId: "current")
        pairings.refreshAgents([], host: host, deviceId: "replaced")
        let restored = Pairings(account: account, publishes: false)
        while restored.state == .unreadable { await Task.yield() }
        XCTAssertEqual(restored.active?.agents, [conversation.agent])
        restored.refreshAgents([], host: host, deviceId: "current")
        XCTAssertEqual(restored.active?.agents, [])
    }

    func testInactiveHostDiscoversAgentsWithoutSwitching() async throws {
        let account = "test-inactive-" + UUID().uuidString
        defer { try? IdentityKeychain.remove(account: account) }
        let pairings = Pairings(account: account, publishes: false)
        pairings.loadIfNeeded()
        let inactive = URL(string: "https://old.example.com")!
        let active = URL(string: "https://active.example.com")!
        for host in [inactive, active] {
            try pairings.add(FixtureAppService.pairing, host: host, features: [])
        }
        await pairings.refreshInactiveAgents { _ in FixtureAppService() }
        XCTAssertEqual(pairings.active?.host, active)
        XCTAssertEqual(pairings.entries.first { $0.host == inactive }?.features.contains("agents"), true)
        XCTAssertEqual(pairings.active?.features, [])
    }

    /// The signed start, end and cancel as the contract fixtures write them, and the fixture grant decoded.
    func testPairedRequestsMatchTheContract() async throws {
        let grantBody = try fixture("callGrant")
        let expectedStart = try JSONDecoder().decode(CallRequest.self, from: fixture("callRequest"))
        let seen = Mutex<[URLRequest]>([])
        Stub.handler.withLock { $0 = { request in
            seen.withLock { $0.append(request) }
            return (200, request.url!.path == "/app/calls" ? grantBody : Data())
        } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let key = P256.Signing.PrivateKey()
        let service = SignedClient(host: URL(string: "https://example.invalid")!, deviceId: "dev_test",
            configuration: configuration, signer: { data, _ in try key.signature(for: data).derRepresentation })
        let target = CallTarget(paired: PairedCallTarget(host: URL(string: "https://example.invalid")!,
            deviceId: "dev_test", conversation: conversation), service: service, attemptId: expectedStart.attemptId)
        let grant = try await target.grant()
        XCTAssertEqual(grant.callId, "call_5tGh2")
        XCTAssertEqual(grant.agent, "Taylor")
        XCTAssertEqual(grant.names.version, 6)
        try await target.end(callId: grant.callId, reason: nil)
        try await target.cancel()
        let requests = seen.withLock { $0 }
        XCTAssertEqual(requests.map { $0.url!.path }, ["/app/calls", "/app/calls/call_5tGh2/end", "/app/calls/attempts/\(expectedStart.attemptId)/cancel"])
        let bodies = requests.map(\.bodyBytes)
        XCTAssertEqual(try JSONDecoder().decode(CallRequest.self, from: bodies[0]), expectedStart)
        XCTAssertEqual(try JSONDecoder().decode(CallEndRequest.self, from: bodies[1]),
            try JSONDecoder().decode(CallEndRequest.self, from: fixture("callEndRequest")))
        XCTAssertEqual(try JSONDecoder().decode(CallCancelRequest.self, from: bodies[2]),
            try JSONDecoder().decode(CallCancelRequest.self, from: fixture("callCancelRequest")))
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("HeyDan-Sig v=1,p=1,d=dev_test,") == true)
        }
    }

    func testCancelWhileGrantIsPendingUsesTheSameAttempt() async throws {
        let service = CallServiceSpy()
        service.delaysGrant = true
        let target = CallTarget(paired: PairedCallTarget(host: URL(string: "https://example.invalid")!,
            deviceId: "dev_test", conversation: conversation), service: service)
        let pending = Task { try await target.grant() }
        let deadline = ContinuousClock.now + .seconds(2)
        while service.pendingGrant == nil, ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try XCTUnwrap(service.pendingGrant)
        try await target.cancel()
        XCTAssertEqual(service.cancels.first?.0, target.attemptId)
        continuation.resume()
        service.pendingGrant = nil
        let grant = try await pending.value
        try await target.end(callId: grant.callId, reason: nil)
        XCTAssertEqual(service.ends.first?.0, grant.callId)
    }

    /// A grant for another attempt is a call this app cannot match: it ends that call and cancels its own attempt.
    func testMismatchedAttemptEndsTheCallAndCancels() async throws {
        let service = CallServiceSpy()
        service.grantAttempt = "another-attempt"
        let target = CallTarget(paired: PairedCallTarget(host: URL(string: "https://example.com")!, deviceId: "dev_test",
            conversation: conversation), service: service)
        do {
            _ = try await target.grant()
            XCTFail("a mismatched attempt must not be joined")
        } catch { XCTAssertEqual(error, .malformedGrant) }
        XCTAssertEqual(service.starts.first?.voiceProtocol, VoiceProtocol.requestedVersion)
        XCTAssertNil(service.starts.first?.jev)
        XCTAssertEqual(service.ends.first?.0, "call_test")
        XCTAssertEqual(service.ends.first?.1.reason, "updating")
        XCTAssertEqual(service.cancels.first?.0, target.attemptId)
        XCTAssertNotEqual(CallTarget(paired: target.paired, service: service).attemptId, target.attemptId)
    }

    func testPairedFailuresKeepTheirMeaning() {
        let refusal = ErrorBody(error: "no_line", message: "Calls are not set up for this agent.")
        XCTAssertEqual(AppError.server(status: 403, body: refusal).callFailure,
            .server(status: 403, code: "no_line", message: refusal.message))
        XCTAssertEqual(AppError.transport(.invalidResponse).callFailure, .malformedGrant)
        XCTAssertEqual(AppError.transport(.offline).callFailure, .pairedTransport)
        XCTAssertEqual(AppError.keyUnavailable.callFailure.message, AppError.keyUnavailable.message)
        XCTAssertEqual(AppError.notPaired.voiceFailure.message, AppError.notPaired.message)
        XCTAssertEqual(AppError.transport(.invalidResponse).voiceFailure, .malformed)
        XCTAssertEqual(AppError.transport(.timeout).voiceFailure, .pairedTransport)
    }

    func testPairedVoicePickerAdaptsRequests() async throws {
        let service = CallServiceSpy()
        let picker = PairedVoicePickerService(target: PairedCallTarget(host: URL(string: "https://example.com")!,
            deviceId: "dev_test", conversation: conversation), service: service)
        _ = try? await picker.updateVoice(.reset)
        XCTAssertEqual(service.patches.first.map { String(decoding: try! JSONEncoder().encode($0), as: UTF8.self) }, #"{"reset":true}"#)
        let long = String(repeating: "a", count: 511) + "\u{1F600}" + "b"
        _ = try? await picker.voices(VoiceCatalogQuery(provider: "gemini", q: long, language: nil, gender: nil, cursor: nil, limit: 500))
        _ = try? await picker.voices(VoiceCatalogQuery(provider: "gemini", q: nil, language: nil, gender: nil, cursor: nil, limit: 0))
        XCTAssertEqual(service.catalogQueries.first?.q, String(repeating: "a", count: 511))
        XCTAssertEqual(service.catalogQueries.map(\.limit), [100, 1])
        do {
            _ = try await picker.voice()
            XCTFail("the spy refuses")
        } catch { XCTAssertEqual(error, .pairedTransport) }
    }
}

@MainActor private final class CallServiceSpy: AppService {
    var delaysGrant = false
    var grantAttempt: String?
    var patches: [TTSPatch] = []
    var catalogQueries: [VoiceCatalogQuery] = []
    var pendingGrant: CheckedContinuation<Void, Never>?
    var starts: [CallRequest] = []
    var ends: [(String, CallEndRequest)] = []
    var cancels: [(String, CallCancelRequest)] = []
    func hello() async throws(AppError) -> HelloResponse { throw .transport(.unavailable) }
    func pair(_ request: PairRequest) async throws(AppError) -> PairResponse { throw .transport(.unavailable) }
    func conversations() async throws(AppError) -> ConversationsResponse { throw .transport(.unavailable) }
    func history(conversationId: String, query: HistoryQuery) async throws(AppError) -> HistoryPage { throw .transport(.unavailable) }
    func send(conversationId: String, request: SendRequest) async throws(AppError) -> SendResponse { throw .transport(.unavailable) }
    func agentStatus(conversationId: String) async throws(AppError) -> AgentStatusResponse {
        throw .transport(.unavailable)
    }
    func updateSettings(agentId: String, request: AgentSettingsRequest) async throws(AppError) -> AgentSettingsResponse {
        throw .transport(.unavailable)
    }
    func agents() async throws(AppError) -> AgentsResponse {
        throw .transport(.unavailable)
    }
    func setAgent(id: String, request: AgentVisibilityRequest) async throws(AppError) -> AgentResponse {
        throw .transport(.unavailable)
    }
    func markUnread(conversationId: String) async throws(AppError) -> ReadResponse {
        throw .transport(.unavailable)
    }
    func markRead(conversationId: String, request: ReadRequest) async throws(AppError) -> ReadResponse { throw .transport(.unavailable) }
    func answer(questionId: String, request: AnswerRequest) async throws(AppError) -> AnswerResponse { throw .transport(.unavailable) }
    func events(query: EventsQuery) async throws(AppError) -> AsyncThrowingStream<AppEvent, any Error> { throw .transport(.unavailable) }
    func initializeFile(_ request: FileInitRequest) async throws(AppError) -> FileInitResponse { throw .transport(.unavailable) }
    func renewFileTicket(fileId: String) async throws(AppError) -> FileTicketRenewResponse { throw .transport(.unavailable) }
    func upload(fileId: String, ticket: String, bytes: Data) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func download(fileId: String) async throws(AppError) -> Data { throw .transport(.unavailable) }
    func startCall(_ request: CallRequest) async throws(AppError) -> CallGrant {
        starts.append(request)
        if delaysGrant { await withCheckedContinuation { pendingGrant = $0 } }
        return CallGrant(protocol: 6, url: "wss://example.com", token: "test", callId: "call_test",
            attemptId: grantAttempt ?? request.attemptId, agent: "Taylor")
    }
    func endCall(callId: String, request: CallEndRequest) async throws(AppError) { ends.append((callId, request)) }
    func cancelCall(attemptId: String, request: CallCancelRequest) async throws(AppError) { cancels.append((attemptId, request)) }
    func voice(conversationId: String) async throws(AppError) -> TTSView { throw .transport(.unavailable) }
    func updateVoice(conversationId: String, request: TTSPatch) async throws(AppError) -> TTSView {
        patches.append(request)
        throw .transport(.unavailable)
    }
    func voices(conversationId: String, query: VoiceCatalogQuery) async throws(AppError) -> CatalogPage {
        catalogQueries.append(query)
        throw .transport(.unavailable)
    }
    func registerPushToken(_ request: PushTokenRequest) async throws(AppError) -> Void { throw .transport(.unavailable) }
    func unpair() async throws(AppError) -> Void { throw .transport(.unavailable) }
}
