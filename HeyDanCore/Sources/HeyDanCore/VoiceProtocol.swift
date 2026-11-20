import Foundation

/// Why a call could not start, worded for the caller.
public enum CallFailure: Error, Equatable, Sendable {
    case pairedTransport
    case server(status: Int, code: String, message: String)
    /// A paired call stopped on this phone before any request: the device key is locked or the host is unpaired.
    case local(code: String, message: String)
    case callKitRefused(String)
    case setupFailed
    /// CallKit never activated the call's audio session.
    case audioNotStarted
    case malformedGrant
    case agentNotListening
    case micUnpublished
    case microphoneDenied
    case noAgent
    case updating
    /// The host speaks a protocol this app does not (the grant's version).
    case unsupportedProtocol(Int)

    /// The case for logs, without the host's or the system's wording.
    public var logName: String {
        switch self {
        case .server(let status, _, _): "server-\(status)"
        case .local(let code, _): "local-\(code)"
        case .callKitRefused: "callKitRefused"
        default: "\(self)"
        }
    }

    public var message: String {
        switch self {
        case .server(_, _, let message), .local(_, let message): message
        case .pairedTransport: "Could not reach the call service. Check your internet connection and try again."
        case let .callKitRefused(detail): "Could not start the call: \(detail)"
        case .setupFailed: "The call could not start. Try again."
        case .audioNotStarted: "The phone did not start the call's audio. Try again."
        case .malformedGrant: "The host answered with something this app does not understand."
        case .agentNotListening: "The voice service joined but did not start listening. Try again."
        case .micUnpublished: "The microphone could not connect to the call. Try again."
        case .microphoneDenied: "Microphone access is off. Turn it on in Settings > Hey Dan."
        case .noAgent: "The voice service did not answer the call."
        case .updating: "The voice service is updating. Try again in a minute."
        case let .unsupportedProtocol(version):
            "This host speaks protocol \(version), which this version of Hey Dan does not. Update the app, then call again."
        }
    }
}

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
