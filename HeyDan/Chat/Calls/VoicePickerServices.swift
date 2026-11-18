import Foundation
import HeyDanCore

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
        do { return try convert(await service.voice(conversationId: target.conversation.id)) }
        catch { throw failure(error) }
    }

    func updateVoice(_ patch: TTSPatch) async throws(TTSServiceFailure) -> TTSView {
        let request: VoicePatchRequest
        switch patch {
        case .reset: request = VoicePatchRequest(reset: true)
        case let .choice(choice):
            request = VoicePatchRequest(provider: choice.provider, model: choice.model, voice: choice.voice)
        }
        guard (try? JSONEncoder().encode(patch).count) ?? Int.max <= 1024 else { throw .invalid(field: "voice") }
        do { return try convert(await service.updateVoice(conversationId: target.conversation.id, request: request)) }
        catch { throw failure(error) }
    }

    func voices(_ query: VoiceCatalogQuery) async throws(TTSServiceFailure) -> CatalogPage {
        var query = query
        query.q = bounded(query.q)
        query.language = bounded(query.language)
        query.gender = bounded(query.gender)
        query.cursor = bounded(query.cursor)
        query.limit = min(max(query.limit ?? 50, 1), 100)
        do {
            let page = try await service.voices(conversationId: target.conversation.id, query: query)
            return CatalogPage(provider: page.provider, voices: page.voices.map {
                VoiceLineCatalogVoice(id: $0.id, name: $0.name, language: $0.language, gender: $0.gender,
                    description: $0.description, preview: $0.preview.flatMap(URL.init(string:)))
            }, next: page.next)
        } catch { throw failure(error) }
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

    private func convert(_ view: VoiceView) throws -> TTSView {
        try JSONDecoder().decode(TTSView.self, from: JSONEncoder().encode(view))
    }

    private func failure(_ error: any Error) -> TTSServiceFailure { (error as? AppError)?.voiceFailure ?? .malformed }
}
