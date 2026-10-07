import Foundation

/// One NanoClaw voice line: the origin of its call link and the link token that admits a call.
public struct VoiceLine: Sendable, Equatable {
    public let origin: URL
    public let host: String
    public let token: String

    /// Parses the call link NanoClaw hands out, `https://<host>/voice?t=<token>`; the host serves the
    /// call routes under `/voice` at the root only.
    public init?(callLink: String) {
        guard let link = URLComponents(string: callLink.trimmingCharacters(in: .whitespacesAndNewlines)),
              link.scheme == "https", let host = link.host, !host.isEmpty,
              link.path == "/voice" || link.path == "/voice/",
              let token = link.queryItems?.first(where: { $0.name == "t" })?.value, !token.isEmpty
        else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = link.port
        guard let url = origin.url else { return nil }
        self.origin = url
        self.host = host
        self.token = token
    }

    public var callLink: String { endpoint(nil).absoluteString }

    /// Admits the call, opens its room and dispatches the worker; answers a `CallGrant`. Asks for
    /// `VoiceProtocol.requestedVersion`, which a protocol 4 host ignores.
    public var tokenRequest: URLRequest {
        var request = URLRequest(url: endpoint("livekit/token", version: VoiceProtocol.requestedVersion))
        request.httpMethod = "POST"
        return request
    }

    /// Ends the call on the host. `reason` is `no-agent` or `updating` when the app gave up on the worker.
    public func endRequest(callId: String, reason: EndReason? = nil) -> URLRequest {
        var request = URLRequest(url: endpoint("livekit/end"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(EndBody(callId: callId, reason: reason?.rawValue))
        return request
    }

    public enum EndReason: String, Sendable {
        case noAgent = "no-agent"
        case updating
    }

    private struct EndBody: Encodable {
        let callId: String
        let reason: String?
    }

    func endpoint(_ route: String?, version: Int? = nil) -> URL {
        let path = route.map { "voice/\($0)" } ?? "voice"
        var components = URLComponents(url: origin.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: token)] + (version.map { [URLQueryItem(name: "v", value: String($0))] } ?? [])
        return components.url!
    }
}

/// The host's answer to `tokenRequest`: where to join, the caller's room token, the call's id for hangup, and the
/// protocol the host speaks.
public struct CallGrant: Decodable, Sendable, Equatable {
    public let url: String
    public let token: String
    public let callId: String
    public let agent: String?
    /// The protocol the host speaks; hosts before protocol 6 named none.
    private let `protocol`: Int?

    /// 4 when the host names none.
    public var protocolVersion: Int { `protocol` ?? 4 }

    /// The worker's names on the host's protocol; nil for one this app does not speak, a call it must not join.
    public var names: VoiceProtocol.Names? { VoiceProtocol.Names(version: protocolVersion) }

    /// Decodes the host's answer, or says why it refused the call.
    public init(status: Int, body: Data) throws(CallFailure) {
        self = try hostAnswer(status: status, body: body)
    }
}

/// A host's JSON answer, or why it refused.
func hostAnswer<Answer: Decodable>(status: Int, body: Data) throws(CallFailure) -> Answer {
    guard (200 ..< 300).contains(status) else {
        throw .refused(status: status, body: String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    do { return try JSONDecoder().decode(Answer.self, from: body) } catch { throw .malformedGrant }
}

/// Why a call could not start, worded for the caller.
public enum CallFailure: Error, Equatable, Sendable {
    /// The host never answered: on this line that almost always means the tailnet is down.
    case unreachable
    /// Found before the call starts: no tailnet interface on the phone, and the line's host is tailnet-only.
    case tailscaleOff
    case noLine
    /// A shortcut named a line no longer saved.
    case lineGone
    case callKitRefused(String)
    case setupFailed
    /// CallKit never activated the call's audio session.
    case audioNotStarted
    /// Any other transport failure (TLS, a malformed response); `detail` is the system's wording.
    case transport(String)
    case refused(status: Int, body: String)
    case malformedGrant
    case microphoneDenied
    case noAgent
    case updating
    case roomConnect
    /// The host speaks a protocol this app does not (the grant's version).
    case unsupportedProtocol(Int)

    /// The case for logs, without the host's or the system's wording.
    public var logName: String {
        switch self {
        case let .refused(status, _): "refused-\(status)"
        case .transport: "transport"
        case .callKitRefused: "callKitRefused"
        default: "\(self)"
        }
    }

    public var message: String {
        switch self {
        case .unreachable: "Can't reach the voice line. Check that Tailscale is connected, then try again."
        case .tailscaleOff: "Tailscale looks off. Turn it on, then call again."
        case .noLine: "Add your call link in Settings first."
        case .lineGone: "That line is gone - pick another in Settings."
        case let .callKitRefused(detail): "Could not start the call: \(detail)"
        case .setupFailed: "The call could not start. Try again."
        case .audioNotStarted: "The phone did not start the call's audio. Try again."
        case let .transport(detail): "Could not reach the voice line: \(detail)"
        case let .refused(status, body):
            switch status {
            case 403: "This call link is not valid."
            case 429 where !body.isEmpty: body
            case 429: "This line has reached its hourly call limit. Try again later."
            // nanoclaw refuses a start on an older protocol: "Reload the page or update your client to protocol 6."
            case 409 where body.contains("update your client"), 426:
                "This voice line needs a newer Hey Dan. Update the app, then call again."
            case 409: "This call attempt is no longer active. Try again."
            case 502: "Could not open the call room. Try again."
            case 503: "The voice line is offline right now."
            default: "Could not start the call (HTTP \(status))."
            }
        case .malformedGrant: "The voice line answered with something this app does not understand."
        case .microphoneDenied: "Microphone access is off. Turn it on in Settings > Hey Dan."
        case .noAgent: "The voice service did not answer the call."
        case .updating: "The voice service is updating. Try again in a minute."
        case .roomConnect: "Could not connect to the call. Check that Tailscale is connected, then try again."
        case let .unsupportedProtocol(version):
            "This voice line speaks protocol \(version), which this version of Hey Dan does not. Update the app, then call again."
        }
    }

    /// What a failed URL load means for the caller: the host never reached (the usual case on a
    /// tailnet-only line) or some other transport failure.
    public init(transportError error: any Error) {
        let unreachable: [URLError.Code] = [
            .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
            .dnsLookupFailed, .secureConnectionFailed,
        ]
        if let error = error as? URLError, unreachable.contains(error.code) { self = .unreachable } else {
            self = .transport(error.localizedDescription)
        }
    }
}

/// The worker's attributes and room metadata, as nanoclaw's `src/channels/voice-mode-protocol.ts` (protocol 6; 4 was
/// `voice-livekit-protocol.ts`) defines them and its browser call page
/// (`.claude/skills/add-voice-mode/ui/src/lib/livekit-call.ts`) reads them. Names that differ per protocol are `Names`.
public enum VoiceProtocol {
    public static let agentStateAttribute = "lk.agent.state"
    /// Without a worker in the room after this long it is down or mid-update.
    public static let agentJoinTimeout: Duration = .seconds(25)
    /// How long CallKit gets to activate the audio session after the call starts before the app gives up on it.
    public static let audioActivationTimeout: Duration = .seconds(5)
    /// The worker times the caller's turn by the silence it hears, so the mic must keep sending it (DTX off).
    public static let micDTX = false

    public enum AgentActivity: Sendable, Equatable {
        case listening, thinking, speaking
    }

    /// The host names why it ended a call in the room metadata right before it deletes the room.
    public static func endReasonText(roomMetadata: String?) -> String? {
        guard let data = roomMetadata?.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(RoomMetadata.self, from: data),
              let end = metadata.end
        else { return nil }
        return endTexts[end]
    }

    private struct RoomMetadata: Decodable {
        let end: String?
    }

    private static let endTexts = [
        "limit_duration": "The call reached its time limit.",
        "limit_daily": "Today's call minutes are used up.",
        "newer_call": "A newer call on this line took over.",
        "revoked": "Access to this line changed.",
        "shutdown": "The voice service restarted.",
        "worker_restart": "The voice service restarted. Call again.",
        "worker_gone": "The voice service dropped the call.",
    ]
}
