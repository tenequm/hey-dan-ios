import AVFAudio
import XCTest
@testable import HeyDan

@MainActor final class VoiceRecordingTests: XCTestCase {
    func testShortManualSendIsDiscardedButTheCapSends() async throws {
        try XCTSkipUnless(AVAudioApplication.shared.recordPermission == .granted, "Needs microphone permission")
        let recording = VoiceRecording()
        defer { recording.finish(.discard) }
        var result: VoiceRecording.Result?
        try recording.start { result = $0 }
        recording.finish(.send)
        guard case .dismissed(let note) = result else { return XCTFail("Short manual recording was kept") }
        XCTAssertEqual(note, "Recording was too short. Record at least one second.")
        XCTAssertNil(VoiceMessagePlayback.shared.recording)

        let finished = expectation(description: "Recorder reached its cap")
        try recording.start(limit: .milliseconds(400)) {
            result = $0
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        guard case .send(let attachment) = result else { return XCTFail("Capped recording was discarded") }
        defer { AttachmentStaging.remove(attachment) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.fileURL.path))
        XCTAssertLessThan(try XCTUnwrap(attachment.durationMs), 1000)
        XCTAssertNil(VoiceMessagePlayback.shared.recording)
    }
}
