import Foundation
import HeyDanCore

struct PairedCallTarget: Sendable, Equatable {
    let host: URL
    let deviceId: String
    let conversation: Conversation

    var agentHandle: UUID { PairedAgentID.make(host: host, agentId: conversation.agent.id) }
}

struct CallTarget {
    let paired: PairedCallTarget
    let service: any AppService
    let attemptId: String

    init(paired: PairedCallTarget, service: any AppService, attemptId: String = UUID().uuidString) {
        self.paired = paired
        self.service = service
        self.attemptId = attemptId
    }

    struct Grant {
        let url: String
        let token: String
        let callId: String
        let agent: String?
        let names: VoiceProtocol.Names
    }

    var usesRelay: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HEYDAN_PAIRED_ICE"] == "all" { return false }
        #endif
        return true
    }

    /// The host's grant and the names of the protocol it speaks. A grant on a protocol this app does not speak is never
    /// joined: its call ends on the host right away.
    func grant() async throws(CallFailure) -> Grant {
        let grant: CallGrant
        do {
            grant = try await service.startCall(CallRequest(conversationId: paired.conversation.id,
                attemptId: attemptId, voiceProtocol: VoiceProtocol.requestedVersion, jev: nil))
        } catch { throw error.callFailure }
        guard grant.attemptId == attemptId else {
            // The host started a call this app cannot match to its attempt: end that call, then the attempt.
            try? await end(callId: grant.callId, reason: .updating)
            try? await cancel()
            throw .malformedGrant
        }
        guard let names = VoiceProtocol.Names(version: grant.protocol) else {
            try? await end(callId: grant.callId, reason: .updating)
            throw .unsupportedProtocol(grant.protocol)
        }
        return Grant(url: grant.url, token: grant.token, callId: grant.callId, agent: grant.agent, names: names)
    }

    enum EndReason: String {
        case agentNotListening = "agent-not-listening"
        case micUnpublished = "mic-unpublished"
        case noAgent = "no-agent"
        case updating
    }

    func end(callId: String, reason: EndReason?) async throws {
        let tag = "cid=\(callId.prefix(8)) end reason=\(reason?.rawValue ?? "hangup")"
        let asked = ContinuousClock.now
        do {
            try await service.endCall(callId: callId, request: CallEndRequest(reason: reason?.rawValue ?? "hangup"))
            CallLog.log(.net, "\(tag) acknowledged ms=\(CallLog.ms(since: asked)) paired=true")
        } catch {
            CallLog.log(.net, "\(tag) failed \(CallLog.describe(error))", level: .error)
            throw error
        }
    }

    func cancel() async throws {
        try await service.cancelCall(attemptId: attemptId, request: CallCancelRequest(reason: "hangup"))
    }

    @MainActor var voicePickerService: (any VoicePickerService)? {
        guard Pairings.shared.entries.contains(where: { $0.host == paired.host && $0.deviceId == paired.deviceId && $0.features.contains("voice-picker") }) else { return nil }
        return PairedVoicePickerService(target: paired, service: service)
    }
}
