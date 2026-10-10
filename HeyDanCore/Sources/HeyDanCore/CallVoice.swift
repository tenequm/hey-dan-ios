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

public struct LiveVoice: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case draft
        case requesting(gen: Int)
        case queued
        case active
        case refused(reason: String)
        case unconfirmed
    }

    public let callID: UUID
    public private(set) var state: CallVoiceState?
    public private(set) var draft: TTSChoice?
    public private(set) var phase: Phase
    public private(set) var request: VoiceRequest?
    public private(set) var inFlight = false
    private var resolvedChoice: TTSChoice?

    public init(callID: UUID, state: CallVoiceState? = nil) {
        self.callID = callID
        self.state = state
        phase = state.map { $0.pending == nil ? .active : .queued } ?? .draft
    }

    public mutating func edit(_ choice: TTSChoice) {
        guard !inFlight else { return }
        draft = choice
        request = nil
        resolvedChoice = nil
        phase = .draft
    }

    @discardableResult
    public mutating func begin(_ choice: TTSChoice, gen: Int, for id: UUID) -> Bool {
        guard id == callID, !inFlight, state != nil else { return false }
        draft = choice
        if request?.tts != choice { resolvedChoice = nil }
        request = VoiceRequest(gen: gen, tts: choice)
        inFlight = true
        phase = .requesting(gen: gen)
        return true
    }

    @discardableResult
    public mutating func apply(reply: ReviewReply, for id: UUID) -> Bool {
        guard id == callID, let request, reply.gen == request.gen, inFlight else { return false }
        inFlight = false
        if reply.ok {
            phase = .queued
            reconcile()
        } else {
            phase = .refused(reason: reply.error ?? "refused")
        }
        return true
    }

    @discardableResult
    public mutating func apply(attribute: String?, for id: UUID) -> Bool {
        guard id == callID else { return false }
        let next = attribute.flatMap(CallVoiceState.init(attribute:))
        if let previousGen = state?.gen, let nextGen = next?.gen, nextGen < previousGen { return false }
        state = next
        if request == nil {
            if draft == nil { phase = next.map { $0.pending == nil ? .active : .queued } ?? .draft }
        } else if case .refused = phase {
            return true
        } else {
            reconcile()
        }
        return true
    }

    @discardableResult
    public mutating func timeout(gen: Int, for id: UUID) -> Bool {
        guard id == callID, request?.gen == gen, inFlight else { return false }
        inFlight = false
        phase = .unconfirmed
        reconcile()
        return true
    }

    public var outcome: VoiceRequestOutcome {
        switch phase {
        case .queued, .active:
            request.map { .queued(gen: $0.gen) } ?? .unsupported
        case let .refused(reason): .refused(reason: reason)
        case .draft, .requesting, .unconfirmed: .unconfirmed
        }
    }

    private mutating func reconcile() {
        guard let request, let state else { return }
        let choice = state.gen == request.gen ? request.tts : resolvedChoice ?? request.tts
        // An older attribute cannot resolve omitted provider defaults for this request.
        guard state.gen == request.gen || (choice.model != nil && choice.voice != nil) else { return }
        if let pending = state.pending {
            if matches(choice, pending) {
                resolvedChoice = pending
                phase = .queued
            }
        } else if matches(choice, state.active) {
            resolvedChoice = state.active
            phase = .active
        }
    }

    private func matches(_ choice: TTSChoice, _ configured: TTSChoice) -> Bool {
        choice.provider == configured.provider
            && (choice.model == nil || choice.model == configured.model)
            && (choice.voice == nil || choice.voice == configured.voice)
    }
}
