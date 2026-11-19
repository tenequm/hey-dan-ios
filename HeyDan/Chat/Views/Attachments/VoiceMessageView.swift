import AVFAudio
import HeyDanCore
import SwiftUI

func voiceDuration(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1000)
    return String(format: "%ld:%02ld", seconds / 60, seconds % 60)
}

struct VoiceWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule().frame(width: 3, height: max(3, 18 * levels[index]))
            }
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }
}

@MainActor @Observable final class VoiceMessagePlayback: NSObject, AVAudioPlayerDelegate {
    static let shared = VoiceMessagePlayback()
    var recording: VoiceRecording?
    private(set) var fileID: String?
    private(set) var playing = false
    private(set) var loading = false
    private(set) var failedID: String?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    private var ownsSession = false
    private var interruption: NotificationCenter.ObservationToken?

    override private init() {
        super.init()
        interruption = NotificationCenter.default.addObserver(of: AVAudioSession.sharedInstance(), for: .didBecomeInactive) { [weak self] message in
            guard case .systemInterruption = message.deactivationResult, let self else { return }
            recording?.finish(.interrupted)
            if loading { stop() } else { pause() }
        }
    }

    func toggle(_ file: FileAttachment) {
        guard recording == nil, !CallController.shared.isCallActive else { return }
        if fileID == file.id, let player {
            if playing { pause() } else { play(player, fileID: file.id) }
            return
        }
        stop()
        fileID = file.id
        loading = true
        task = Task {
            do {
                let url = try await ChatController.shared.download(file)
                try Task.checkCancellation()
                guard !CallController.shared.isCallActive else { stop(); return }
                let audio = try AVAudioPlayer(contentsOf: url)
                player = audio
                audio.delegate = self
                loading = false
                play(audio, fileID: file.id)
            } catch {
                guard !Task.isCancelled else { return }
                stop()
                failedID = file.id
            }
        }
    }

    private func play(_ audio: AVAudioPlayer, fileID: String) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            ownsSession = true
            guard audio.play() else { throw CocoaError(.fileReadUnknown) }
            playing = true
        } catch {
            stop()
            failedID = fileID
        }
    }

    private func pause() {
        player?.pause()
        playing = false
        releaseSession()
    }

    private func releaseSession() {
        guard ownsSession else { return }
        ownsSession = false
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { CallLog.log(.audio, "voice playback release failed", level: .error) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            let failed = flag ? nil : fileID
            stop()
            failedID = failed
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        releaseSession()
        player = nil
        fileID = nil
        playing = false
        loading = false
        failedID = nil
    }
}

struct VoiceMessageView: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    var file: FileAttachment?
    let durationMs: Int?
    private let playback = VoiceMessagePlayback.shared
    private var selected: Bool { file != nil && playback.fileID == file?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s1) {
            switch file?.transcript?.state {
            case .done:
                Text(file?.transcript?.text ?? "Voice message").textSelection(.enabled)
            case .failed:
                Text("Couldn't transcribe. The agent got the audio.").foregroundStyle(theme.color.textTertiary)
            case .pending:
                Text("Transcribing...").foregroundStyle(theme.color.textTertiary)
            case .unknown, nil:
                Text("Voice message")
            }
            Button {
                if let file { playback.toggle(file) }
            } label: {
                HStack(spacing: theme.space.s1_5) {
                    Group {
                        if selected && playback.loading { ProgressView().controlSize(.mini) }
                        else { Image(systemName: selected && playback.playing ? "pause.fill" : "play") }
                    }
                    .frame(width: 24, height: 24).background(theme.color.surfaceSubtle, in: Circle())
                    VoiceWaveform(levels: [0.2, 0.4, 0.7, 0.4, 0.9, 0.55, 0.3, 0.75, 0.4, 0.2, 0.65, 0.4])
                    if let durationMs { Text(voiceDuration(durationMs)).monospacedDigit() }
                }
                .textRole(theme.type.caption)
                .foregroundStyle(theme.color.textSecondary)
                .frame(minHeight: theme.control.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected && playback.playing ? "Pause voice message" : "Play voice message")
            .accessibilityValue(durationMs.map(voiceDuration) ?? "")
            .accessibilityIdentifier("chat.voice.play")
            .disabled(file == nil || playback.recording != nil || CallController.shared.isCallActive)
            if let file, playback.failedID == file.id {
                Text("Could not play the recording. Tap play to retry.")
                    .textRole(theme.type.caption).foregroundStyle(theme.color.danger)
            }
        }
        .onDisappear { if selected { playback.stop() } }
        .onChange(of: scenePhase) { if selected && scenePhase == .background { playback.stop() } }
    }
}
