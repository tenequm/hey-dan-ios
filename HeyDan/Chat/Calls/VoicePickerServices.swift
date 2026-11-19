import Foundation
import HeyDanCore

enum VoicePickerIdentity: Hashable, Sendable {
    case paired(host: URL, deviceId: String, conversationId: String)
}

protocol VoicePickerService: Sendable {
    var identity: VoicePickerIdentity { get }
    func voice() async throws(TTSServiceFailure) -> TTSView
    func updateVoice(_ request: TTSPatch) async throws(TTSServiceFailure) -> TTSView
    func voices(_ query: VoiceCatalogQuery) async throws(TTSServiceFailure) -> CatalogPage
}

struct PairedVoicePickerService: VoicePickerService {
    let target: PairedCallTarget
    let service: any AppService
    var identity: VoicePickerIdentity {
        .paired(host: target.host, deviceId: target.deviceId, conversationId: target.conversation.id)
    }

    func voice() async throws(TTSServiceFailure) -> TTSView {
        do { return try await service.voice(conversationId: target.conversation.id) }
        catch { throw error.voiceFailure }
    }

    func updateVoice(_ patch: TTSPatch) async throws(TTSServiceFailure) -> TTSView {
        guard (try? JSONEncoder().encode(patch).count) ?? Int.max <= 1024 else { throw .invalid(field: "voice") }
        do { return try await service.updateVoice(conversationId: target.conversation.id, request: patch) }
        catch { throw error.voiceFailure }
    }

    func voices(_ query: VoiceCatalogQuery) async throws(TTSServiceFailure) -> CatalogPage {
        var query = query
        query.q = bounded(query.q)
        query.language = bounded(query.language)
        query.gender = bounded(query.gender)
        query.cursor = bounded(query.cursor)
        query.limit = min(max(query.limit ?? 50, 1), 100)
        do {
            return try await service.voices(conversationId: target.conversation.id, query: query)
        } catch { throw error.voiceFailure }
    }

    private func bounded(_ value: String?) -> String? {
        value.map { value in
            var count = 0
            return String(String.UnicodeScalarView(value.unicodeScalars.prefix { scalar in
                count += scalar.value > 0xffff ? 2 : 1
                return count <= 512
            }))
        }
    }
}
