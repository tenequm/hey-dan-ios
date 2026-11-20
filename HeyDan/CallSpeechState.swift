import Foundation

struct CallerCaption: Equatable {
    private(set) var text = ""
    private(set) var isFinal = false
    private var startMs = -1

    mutating func update(_ text: String, at start: Int, final: Bool) {
        guard start > startMs || (start == startMs && !isFinal) else { return }
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        startMs = start
        isFinal = final
    }
}

struct CallerWord {
    let text: String
    let startMs: Int
    let confidence: Double?

    private static let minimumCutConfidence = 0.6
    private static let acknowledgements: Set<String> = [
        "uh", "huh", "uhhuh", "ok", "okay", "mm", "hmm", "mhm",
        "ugu", "aga", "tak", "nu", "da", "угу", "ага", "так", "ну", "да"
    ]

    var interrupts: Bool {
        guard let confidence, confidence >= Self.minimumCutConfidence else { return false }
        return text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .contains { !Self.acknowledgements.contains(String($0)) }
    }
}

struct SpeechInterrupt {
    let heard: String
    let cutAtMs: Int

    func payload(micMs: Int) throws -> String {
        // LiveKit does not expose a per-utterance playout position.
        let fields: [String: Any] = ["heard": heard, "cutAtMs": cutAtMs, "micMs": micMs, "playedMs": NSNull()]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }
}

@MainActor
final class SpeechBargeIn {
    private let replyTimeout: Duration
    private let trace: (String) -> Void
    private var speakingSince: Int?
    private var attempted = false
    private var restore: (() -> Void)?
    private var deadline: Task<Void, Never>?
    private var request: Task<Void, Never>?

    init(replyTimeout: Duration = .milliseconds(800), trace: @escaping (String) -> Void = { _ in }) {
        self.replyTimeout = replyTimeout
        self.trace = trace
    }

    func update(enabled: Bool, speaking: Bool, micMs: Int) {
        if !enabled {
            reset(reason: "disabled")
        } else if speaking, speakingSince == nil {
            reset(reason: "next utterance")
            speakingSince = micMs
        } else if !speaking {
            speakingSince = nil
        }
    }

    func hear(_ words: [CallerWord], remoteActive: Bool, mute: () -> (() -> Void)?,
              interrupt: @escaping (SpeechInterrupt) async -> Bool?) {
        guard remoteActive, !attempted, let speakingSince else { return }
        let current = words.filter { $0.startMs >= speakingSince }
        guard current.contains(where: \.interrupts), let first = current.first, let restore = mute() else { return }
        let heard = current.filter { $0.startMs >= first.startMs }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
        let cut = SpeechInterrupt(heard: heard, cutAtMs: first.startMs)
        attempted = true
        self.restore = restore
        let mutedAt = ContinuousClock.now
        let replyBy = mutedAt + replyTimeout
        deadline = Task {
            do { try await Task.sleep(until: replyBy, clock: .continuous) } catch { return }
            guard !Task.isCancelled else { return }
            request?.cancel()
            trace("interrupt reply=timed_out ms=\(CallLog.ms(since: mutedAt))")
            restoreVolume(reason: "deadline")
        }
        request = Task {
            guard !Task.isCancelled, .now < replyBy else { return }
            guard let accepted = await interrupt(cut), !Task.isCancelled, .now < replyBy else { return }
            deadline?.cancel()
            trace("interrupt reply=\(accepted ? "accepted" : "refused") ms=\(CallLog.ms(since: mutedAt))")
            guard accepted else {
                restoreVolume(reason: "refused")
                return
            }
            let restoreBy = mutedAt + replyTimeout * 3
            do { try await Task.sleep(until: restoreBy, clock: .continuous) } catch { return }
            guard !Task.isCancelled else { return }
            restoreVolume(reason: "accepted cap")
        }
    }

    func reset(reason: String) {
        request?.cancel()
        deadline?.cancel()
        request = nil
        deadline = nil
        restoreVolume(reason: reason)
        speakingSince = nil
        attempted = false
    }

    private func restoreVolume(reason: String) {
        guard let restore else { return }
        restore()
        trace("interrupt restored reason=\(reason)")
        self.restore = nil
    }
}
