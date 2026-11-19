import AVFAudio
import HeyDanCore
import SwiftUI

struct VoiceRecorder: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    let dismiss: (String?) -> Void
    let send: (StagedAttachment) -> Void
    @State private var recorder: AVAudioRecorder?
    @State private var elapsed = 0
    @State private var levels = Array(repeating: CGFloat(0.12), count: 22)
    private static let limit = 600

    var body: some View {
        HStack(spacing: theme.space.s1_5) {
            Button {
                discard()
                dismiss(nil)
            } label: {
                Image(systemName: "trash").foregroundStyle(theme.color.danger)
                    .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
            }
            .accessibilityLabel("Discard recording")
            .accessibilityIdentifier("composer.recording.discard")
            Circle().fill(theme.color.danger).frame(width: 8, height: 8)
            Text(voiceDuration(elapsed)).monospacedDigit().foregroundStyle(theme.color.textPrimary)
            VoiceWaveform(levels: levels).foregroundStyle(theme.color.textTertiary)
            Spacer(minLength: 0)
            Button { finish() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: theme.type.body.size, weight: theme.weight.bold))
                    .foregroundStyle(theme.color.onAccent)
                    .frame(width: theme.type.display.size, height: theme.type.display.size)
                    .background(theme.color.accent, in: Circle())
                    .frame(width: theme.control.touchTarget, height: theme.control.touchTarget)
            }
            .disabled(recorder == nil)
            .accessibilityLabel("Send voice message")
            .accessibilityIdentifier("composer.recording.send")
        }
        .buttonStyle(.plain)
        .padding(.vertical, theme.space.s0_5)
        .task { await record() }
        .onDisappear { discard() }
        .onChange(of: scenePhase) { if scenePhase == .background { discard(); dismiss(nil) } }
        .onChange(of: CallController.shared.isCallActive) { if CallController.shared.isCallActive { discard(); dismiss(nil) } }
    }

    private func record() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled else { return }
        guard granted else { dismiss("Allow microphone access in Settings to record a voice message."); return }
        guard !CallController.shared.isCallActive else { dismiss("End the call to record a voice message."); return }
        let session = AVAudioSession.sharedInstance()
        var target: URL?
        do {
            VoiceMessagePlayback.shared.stop()
            let url = try AttachmentStaging.destination(extension: "m4a")
            target = url
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try session.setActive(true)
            let audio = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
            ])
            audio.isMeteringEnabled = true
            guard audio.record(forDuration: Double(Self.limit)) else { throw CocoaError(.fileWriteUnknown) }
            recorder = audio
            VoiceMessagePlayback.shared.recording = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            while !Task.isCancelled, recorder != nil {
                if !audio.isRecording {
                    let length = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
                    if length >= Double(Self.limit) - 0.1 { finish(at: Self.limit * 1000) }
                    else { discard(); dismiss("Recording was interrupted. Try again.") }
                    return
                }
                elapsed = Int(audio.currentTime * 1000)
                audio.updateMeters()
                levels.removeFirst()
                levels.append(CGFloat(max(0.12, min(1, (audio.averagePower(forChannel: 0) + 50) / 50))))
                try? await Task.sleep(for: .milliseconds(80))
            }
        } catch {
            if let target { try? FileManager.default.removeItem(at: target) }
            releaseSession()
            dismiss("Could not start recording. Try again.")
        }
    }

    private func finish(at duration: Int? = nil) {
        guard let recorder else { return }
        let milliseconds = duration ?? max(1, Int(recorder.currentTime * 1000))
        recorder.stop()
        self.recorder = nil
        releaseSession()
        send(StagedAttachment(fileURL: recorder.url, name: "Voice message.m4a", mimeType: "audio/mp4", durationMs: milliseconds))
    }

    private func discard() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        self.recorder = nil
        releaseSession()
    }

    private func releaseSession() {
        VoiceMessagePlayback.shared.recording = false
        if !CallController.shared.isCallActive {
            let session = AVAudioSession.sharedInstance()
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(false)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
