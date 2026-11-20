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

    private static let acknowledgements: Set<String> = [
        "uh", "huh", "uhhuh", "ok", "okay", "mm", "hmm", "mhm",
        "ugu", "aga", "tak", "nu", "da", "угу", "ага", "так", "ну", "да"
    ]

    var interrupts: Bool {
        guard let confidence, confidence >= 0.6 else { return false }
        return text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .contains { !Self.acknowledgements.contains(String($0)) }
    }
}

struct SpeechInterrupt {
    let heard: String
    let cutAtMs: Int

    func payload(from input: CallSpeechInput) throws -> String {
        // LiveKit does not expose a per-utterance playout position.
        let fields: [String: Any] = ["heard": heard, "cutAtMs": cutAtMs, "micMs": input.milliseconds, "playedMs": NSNull()]
        return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }
}

@MainActor
final class SpeechBargeIn {
    private let timeout: Duration
    private var speakingSince: Int?
    private var attempted = false
    private var restore: (() -> Void)?
    private var deadline: Task<Void, Never>?
    private var request: Task<Void, Never>?

    init(timeout: Duration = .milliseconds(800)) { self.timeout = timeout }

    func update(enabled: Bool, speaking: Bool, micMs: Int) {
        if !enabled {
            reset()
        } else if speaking, speakingSince == nil {
            reset()
            speakingSince = micMs
        } else if !speaking {
            speakingSince = nil
        }
    }

    func hear(_ words: [CallerWord], remoteActive: Bool, mute: () -> (() -> Void)?,
              interrupt: @escaping (SpeechInterrupt) async -> Bool) {
        guard remoteActive, !attempted, let speakingSince else { return }
        let current = words.filter { $0.startMs >= speakingSince }
        guard current.contains(where: \.interrupts), let first = current.first, let restore = mute() else { return }
        let heard = current.filter { $0.startMs >= first.startMs }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
        let cut = SpeechInterrupt(heard: heard, cutAtMs: first.startMs)
        attempted = true
        self.restore = restore
        deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            request?.cancel()
            restoreVolume()
        }
        request = Task {
            guard !Task.isCancelled else { return }
            let accepted = await interrupt(cut)
            guard !Task.isCancelled, accepted else { return }
            deadline?.cancel()
        }
    }

    func reset() {
        request?.cancel()
        deadline?.cancel()
        request = nil
        deadline = nil
        restoreVolume()
        speakingSince = nil
        attempted = false
    }

    private func restoreVolume() {
        restore?()
        restore = nil
    }
}
