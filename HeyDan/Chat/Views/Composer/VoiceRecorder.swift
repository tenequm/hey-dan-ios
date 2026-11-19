import AVFAudio
import HeyDanCore
import SwiftUI

struct VoiceRecorder: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    let completed: (VoiceRecording.Result) -> Void
    @State private var recording = VoiceRecording()
    @State private var preparing = true

    var body: some View {
        HStack(spacing: theme.space.s1_5) {
            Button {
                if recording.active { recording.finish(.discard) } else { completed(.dismissed(nil)) }
            } label: {
                Image(systemName: "trash").foregroundStyle(theme.color.danger)
                    .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
            }
            .accessibilityLabel("Discard recording")
            .accessibilityIdentifier("composer.recording.discard")
            HStack(spacing: theme.space.s1_5) {
                Circle().fill(theme.color.danger).frame(width: 8, height: 8)
                Text(voiceDuration(recording.elapsed)).monospacedDigit().foregroundStyle(theme.color.textPrimary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(recording.active ? "Recording" : "Preparing microphone")
            .accessibilityValue(voiceDuration(recording.elapsed))
            .accessibilityIdentifier("composer.recording.status")
            VoiceWaveform(levels: recording.levels).foregroundStyle(theme.color.textTertiary)
            Spacer(minLength: 0)
            Button { recording.finish(.send) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: theme.type.body.size, weight: theme.weight.bold))
                    .foregroundStyle(theme.color.onAccent)
                    .frame(width: theme.type.display.size, height: theme.type.display.size)
                    .background(theme.color.accent, in: Circle())
                    .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
            }
            .disabled(!recording.active)
            .accessibilityLabel("Send voice message")
            .accessibilityIdentifier("composer.recording.send")
        }
        .buttonStyle(.plain)
        .padding(.vertical, theme.space.s0_5)
        .task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard !Task.isCancelled, scenePhase != .background else { return }
            preparing = false
            guard granted else { completed(.dismissed("Allow microphone access in Settings to record a voice message.")); return }
            guard !CallController.shared.isCallActive else { completed(.dismissed("End the call to record a voice message.")); return }
            do { try recording.start(completed: completed) }
            catch { completed(.dismissed("Could not start recording. Try again.")) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .background {
                if preparing { completed(.dismissed(nil)) } else { recording.finish(.interrupted) }
            }
        }
        .onDisappear { recording.finish(.discard) }
    }
}

@MainActor @Observable final class VoiceRecording {
    enum Stop { case discard, send, limit, interrupted }
    enum Result {
        case dismissed(String?)
        case send(StagedAttachment)
        case staged(StagedAttachment)
    }

    private(set) var elapsed = 0
    private(set) var levels = Array(repeating: CGFloat(0.12), count: 22)
    var active: Bool { recorder != nil }
    private var recorder: AVAudioRecorder?
    private var completed: ((Result) -> Void)?
    private var timer: Task<Void, Never>?

    func start(limit: Duration = .seconds(600), completed: @escaping (Result) -> Void) throws {
        let playback = VoiceMessagePlayback.shared
        guard playback.recording == nil, !CallController.shared.isCallActive else { throw CocoaError(.userCancelled) }
        playback.stop()
        let url = try AttachmentStaging.destination(extension: "m4a")
        let session = AVAudioSession.sharedInstance()
        var activated = false
        do {
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            activated = true
            let audio = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
            ])
            audio.isMeteringEnabled = true
            guard audio.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = audio
            self.completed = completed
            playback.recording = self
            let deadline = ContinuousClock.now + limit
            timer = Task {
                while !Task.isCancelled {
                    guard audio.isRecording else { finish(.interrupted); return }
                    guard ContinuousClock.now < deadline else { finish(.limit); return }
                    elapsed = Int(audio.currentTime * 1000)
                    audio.updateMeters()
                    levels.removeFirst()
                    levels.append(CGFloat(max(0.12, min(1, (audio.averagePower(forChannel: 0) + 50) / 50))))
                    try? await Task.sleep(until: min(deadline, .now + .milliseconds(80)), clock: .continuous)
                }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AccessibilityNotification.Announcement("Recording started").post()
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(false)
            if activated { deactivate() }
            throw error
        }
    }

    func finish(_ reason: Stop) {
        guard let recorder, let completed else { return }
        timer?.cancel()
        timer = nil
        let duration = max(elapsed, Int(recorder.currentTime * 1000))
        recorder.stop()
        self.recorder = nil
        self.completed = nil
        VoiceMessagePlayback.shared.recording = nil
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(false)
        deactivate()
        AccessibilityNotification.Announcement("Recording stopped").post()
        if reason == .discard {
            recorder.deleteRecording()
            completed(.dismissed(nil))
            return
        }
        // An interrupted recorder can reset currentTime before the final meter update.
        let measured = (try? AVAudioPlayer(contentsOf: recorder.url).duration).map { Int($0 * 1000) } ?? duration
        guard reason == .limit || measured >= 1000 else {
            recorder.deleteRecording()
            completed(.dismissed("Recording was too short. Record at least one second."))
            return
        }
        let attachment = StagedAttachment(fileURL: recorder.url, name: "Voice message.m4a", mimeType: "audio/mp4",
                                          durationMs: max(1, measured))
        completed(reason == .interrupted ? .staged(attachment) : .send(attachment))
    }

    private func deactivate() {
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { CallLog.log(.audio, "voice recording release failed", level: .error) }
    }
}
