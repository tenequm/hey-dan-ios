import Foundation
import HeyDanCore

/// H6 owns the paired call identity without changing saved line links.
struct PairedCallTarget: Sendable, Equatable {
    let host: URL
    let deviceId: String
    let conversation: Conversation
}

/// H6 adapts the picker to paired and saved-link transports.
protocol VoicePickerService: Sendable {
    func voice() async throws(AppError) -> VoiceView
    func updateVoice(_ request: VoicePatchRequest) async throws(AppError) -> VoiceView
    func voices(_ query: VoiceCatalogQuery) async throws(AppError) -> VoiceCatalog
}
