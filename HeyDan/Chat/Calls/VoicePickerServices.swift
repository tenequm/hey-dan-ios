import Foundation
import HeyDanCore

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

struct LineVoicePickerService: VoicePickerService {
    let savedLine: VoiceLine
    let session: URLSession
    var line: VoiceLine? { savedLine }
    var identity: VoicePickerIdentity { .line(origin: savedLine.origin, credential: savedLine.token) }

    func voice() async throws(TTSServiceFailure) -> TTSView {
        try await fetch(savedLine.ttsRequest)
    }

    func updateVoice(_ patch: TTSPatch) async throws(TTSServiceFailure) -> TTSView {
        let request: URLRequest
        do { request = try savedLine.ttsPatchRequest(patch) }
        catch { throw .invalid(field: "voice") }
        return try await fetch(request)
    }

    func voices(_ query: VoiceCatalogQuery) async throws(TTSServiceFailure) -> CatalogPage {
        try await fetch(savedLine.voicesRequest(provider: query.provider, q: query.q, language: query.language,
            gender: query.gender, cursor: query.cursor, limit: query.limit ?? 50))
    }

    private func fetch<Value: Decodable>(_ input: URLRequest) async throws(TTSServiceFailure) -> Value {
        var request = input
        request.timeoutInterval = 12
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw TTSServiceFailure(transportError: error) }
        guard let response = response as? HTTPURLResponse else { throw .malformed }
        CallLog.log(.net, "picker method=\(request.httpMethod ?? "GET") status=\(response.statusCode)")
        guard (200..<300).contains(response.statusCode) else { throw TTSServiceFailure(status: response.statusCode, body: data) }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw .malformed }
    }
}

struct PairedVoicePickerService: VoicePickerService {
    let target: PairedCallTarget
    let service: any AppService
    var line: VoiceLine? { nil }
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
