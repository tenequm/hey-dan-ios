import Foundation

public struct VoiceRequest: Encodable, Sendable, Equatable {
    public let gen: Int
    public let tts: TTSChoice

    public init(gen: Int, tts: TTSChoice) {
        self.gen = gen
        self.tts = tts
    }

    public var payload: String { rpcPayload(self) }
}

public struct CallVoiceState: Decodable, Sendable, Equatable {
    public let v: Int
    public let active: TTSChoice
    public let pending: TTSChoice?
    public let gen: Int?

    public init(active: TTSChoice, pending: TTSChoice? = nil, gen: Int? = nil) {
        v = 1
        self.active = active
        self.pending = pending
        self.gen = gen
    }

    public init?(attribute: String) {
        guard let state = try? JSONDecoder().decode(Self.self, from: Data(attribute.utf8)), state.v == 1 else { return nil }
        self = state
    }
}

public enum VoiceRequestOutcome: Sendable, Equatable {
    case queued(gen: Int)
    case refused(reason: String)
    case unconfirmed
    case unsupported
    case over
}
