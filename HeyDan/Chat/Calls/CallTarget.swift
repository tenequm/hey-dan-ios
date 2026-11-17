import Foundation
import HeyDanCore
import LiveKit

struct CallTarget {
    let line: VoiceLine?
    let paired: PairedCallTarget?
    let service: (any AppService)?
    let attemptId: String

    init(line: VoiceLine) {
        self.line = line
        paired = nil
        service = nil
        attemptId = UUID().uuidString
    }

    init(paired: PairedCallTarget, service: any AppService, attemptId: String = UUID().uuidString) {
        line = nil
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

    var connectOptions: ConnectOptions {
        ConnectOptions(iceTransportPolicy: usesRelay ? .relay : .all)
    }

    var usesRelay: Bool {
        guard paired != nil else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.environment["HEYDAN_PAIRED_ICE"] == "all" { return false }
        #endif
        return true
    }

    func grant(over http: URLSession, endingOver endHTTP: URLSession? = nil) async throws(CallFailure) -> Grant {
        if let line {
            let data: Data
            let response: URLResponse
            do { (data, response) = try await http.data(for: line.tokenRequest) }
            catch { throw CallFailure(transportError: error) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            CallLog.log(.net, "token status=\(status) bytes=\(data.count)", level: status == 200 ? .info : .error)
            let grant = try VoiceLineGrant(status: status, body: data)
            guard let names = grant.names else {
                Task { try? await end(callId: grant.callId, reason: .updating, over: endHTTP ?? http) }
                throw .unsupportedProtocol(grant.protocolVersion)
            }
            return Grant(url: grant.url, token: grant.token, callId: grant.callId, agent: grant.agent, names: names)
        }
        guard let paired, let service else { throw .setupFailed }
        let grant: CallGrant
        do {
            grant = try await service.startCall(CallRequest(conversationId: paired.conversation.id,
                attemptId: attemptId, voiceProtocol: 6, jev: nil))
        } catch { throw Self.failure(error) }
        guard grant.attemptId == attemptId else {
            try? await cancel(over: http)
            throw .malformedGrant
        }
        guard let names = VoiceProtocol.Names(version: grant.protocol) else {
            try? await end(callId: grant.callId, reason: .updating, over: endHTTP ?? http)
            throw .unsupportedProtocol(grant.protocol)
        }
        return Grant(url: grant.url, token: grant.token, callId: grant.callId, agent: grant.agent, names: names)
    }

    func end(callId: String, reason: VoiceLine.EndReason?, over http: URLSession) async throws {
        if let line {
            let (_, response) = try await http.data(for: line.endRequest(callId: callId, reason: reason))
            CallLog.log(.net, "end status=\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } else if let service {
            try await service.endCall(callId: callId, request: CallEndRequest(reason: reason?.rawValue ?? "hangup"))
        }
    }

    func cancel(over http: URLSession) async throws {
        if let service {
            try await service.cancelCall(attemptId: attemptId, request: CallCancelRequest(reason: "hangup"))
        }
    }

    private static func failure(_ error: AppError) -> CallFailure {
        if case let .server(status, body) = error {
            return .server(status: status, code: body.error, message: body.message)
        }
        return .pairedTransport
    }
}
