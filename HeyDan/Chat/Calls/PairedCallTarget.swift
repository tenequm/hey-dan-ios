import Foundation
import HeyDanCore

struct PairedCallTarget: Sendable, Equatable {
    let host: URL
    let deviceId: String
    let conversation: Conversation
}

enum VoicePickerIdentity: Hashable, Sendable {
    case line(origin: URL, credential: String)
    case paired(host: URL, deviceId: String, conversationId: String)
}

protocol VoicePickerService: Sendable {
    var identity: VoicePickerIdentity { get }
    var line: VoiceLine? { get }
    func voice() async throws(TTSServiceFailure) -> TTSView
    func updateVoice(_ request: TTSPatch) async throws(TTSServiceFailure) -> TTSView
    func voices(_ query: VoiceCatalogQuery) async throws(TTSServiceFailure) -> CatalogPage
}
