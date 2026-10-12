import Foundation
import HeyDanCore
import Testing

struct VoiceSettingsTests {
    @Test func decodesTTSView() throws {
        let json = #"""
        {"effective":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"en-us-techagent-4"},
          "saved":{"provider":"gemini","model":null,"voice":"en-us-techagent-4"},
          "providers":[
           {"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts"],"default":{"model":"gemini-3.8-flash-tts","voice":"Alnilam"}},
           {"id":"elevenlabs","name":"ElevenLabs","available":false,"models":["eleven_turbo_v2_5","eleven_flash_v2_5","eleven_multilingual_v2"],"default":{"model":"eleven_turbo_v2_5","voice":"bIHbv24MWmeRgasZH58o"}}]}
        """#
        let view = try JSONDecoder().decode(TTSView.self, from: Data(json.utf8))
        #expect(view.effective == TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "en-us-techagent-4"))
        #expect(view.saved == SavedTTSChoice(provider: "gemini", voice: "en-us-techagent-4"))
        #expect(!view.saved.isEmpty)
        #expect(view.providers == [
            TTSProvider(id: "gemini", name: "Gemini", available: true,
                        models: ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"],
                        default: TTSDefaults(model: "gemini-3.8-flash-tts", voice: "Alnilam")),
            TTSProvider(id: "elevenlabs", name: "ElevenLabs", available: false,
                        models: ["eleven_turbo_v2_5", "eleven_flash_v2_5", "eleven_multilingual_v2"],
                        default: TTSDefaults(model: "eleven_turbo_v2_5", voice: "bIHbv24MWmeRgasZH58o")),
        ])
    }

    @Test func decodesTTSViewUnsaved() throws {
        let json = #"""
        {"effective":{"provider":"gemini","model":"gemini-3.8-flash-tts","voice":"Alnilam"},"saved":{"provider":null,"model":null,"voice":null},"providers":[
           {"id":"gemini","name":"Gemini","available":true,"models":["gemini-3.8-flash-tts","gemini-3.8-flash-lite-tts"],"default":{"model":"gemini-3.8-flash-tts","voice":"Alnilam"}},
           {"id":"elevenlabs","name":"ElevenLabs","available":false,"models":["eleven_turbo_v2_5","eleven_flash_v2_5","eleven_multilingual_v2"],"default":{"model":"eleven_turbo_v2_5","voice":"bIHbv24MWmeRgasZH58o"}}]}
        """#
        let view = try JSONDecoder().decode(TTSView.self, from: Data(json.utf8))
        #expect(view.effective == TTSChoice(provider: "gemini", model: "gemini-3.8-flash-tts", voice: "Alnilam"))
        #expect(view.saved == SavedTTSChoice())
        #expect(view.saved.isEmpty)
        #expect(view.providers.map(\.id) == ["gemini", "elevenlabs"])
        #expect(view.providers.map(\.available) == [true, false])
    }

    @Test func mapsPatchInvalidFixture() {
        let json = #"""
        {"error":"invalid","field":"voice"}
        """#
        #expect(TTSServiceFailure(status: 400, body: Data(json.utf8)) == .invalid(field: "voice"))
    }

    @Test func mapsPatchUnavailableFixture() {
        let json = #"""
        {"error":"provider_unavailable","provider":"elevenlabs"}
        """#
        #expect(TTSServiceFailure(status: 503, body: Data(json.utf8)) == .providerUnavailable(provider: "elevenlabs"))
    }

    @Test func decodesCatalogGemini() throws {
        let json = #"""
        {"provider":"gemini","voices":[
           {"id":"achernar","name":"Achernar","language":"en-US","gender":"female","description":"Storyteller & Narrator. Soft, calm, and soothing voice with a higher pitch."},
           {"id":"en-us-techagent-4","name":"Tech Advisor 4","language":"en-US","gender":"male","description":"Tech Support Agent / Tech Advisor. Confident and clear."}],
          "next":"eyJvIjoxMDB9"}
        """#
        let page = try JSONDecoder().decode(CatalogPage.self, from: Data(json.utf8))
        #expect(page.provider == "gemini")
        #expect(page.voices == [
            CatalogVoice(id: "achernar", name: "Achernar", language: "en-US", gender: "female",
                         description: "Storyteller & Narrator. Soft, calm, and soothing voice with a higher pitch."),
            CatalogVoice(id: "en-us-techagent-4", name: "Tech Advisor 4", language: "en-US", gender: "male",
                         description: "Tech Support Agent / Tech Advisor. Confident and clear."),
        ])
        #expect(page.next == "eyJvIjoxMDB9")
    }

    @Test func decodesCatalogElevenLast() throws {
        let json = #"""
        {"provider":"elevenlabs","voices":[{"id":"bIHbv24MWmeRgasZH58o","name":"Will","language":"en","gender":"male","preview":"https://example.invalid/w.mp3"}]}
        """#
        let page = try JSONDecoder().decode(CatalogPage.self, from: Data(json.utf8))
        #expect(page.provider == "elevenlabs")
        #expect(page.voices == [CatalogVoice(id: "bIHbv24MWmeRgasZH58o", name: "Will", language: "en", gender: "male",
                                            preview: URL(string: "https://example.invalid/w.mp3"))])
        #expect(page.next == nil)
    }

    @Test(arguments: [#"{}"#, #"{"provider":null,"model":null,"voice":null}"#])
    func omittedAndNullSavedFieldsAreEmpty(json: String) throws {
        let saved = try JSONDecoder().decode(SavedTTSChoice.self, from: Data(json.utf8))
        #expect(saved == SavedTTSChoice())
        #expect(saved.isEmpty)
    }

    @Test(arguments: [#"{"provider":"future"}"#, #"{"provider":"future","model":null,"voice":null}"#])
    func omittedAndNullSavedFieldsPreservePresentValues(json: String) throws {
        let saved = try JSONDecoder().decode(SavedTTSChoice.self, from: Data(json.utf8))
        #expect(saved == SavedTTSChoice(provider: "future"))
        #expect(!saved.isEmpty)
        #expect(!SavedTTSChoice(model: "future-model").isEmpty)
        #expect(!SavedTTSChoice(voice: "future-voice").isEmpty)
    }

    @Test(arguments: [
        #"{"provider":"future","voices":[{"id":"future-voice","name":"Future"}]}"#,
        #"{"provider":"future","voices":[{"id":"future-voice","name":"Future","language":null,"gender":null,"description":null,"preview":null}],"next":null}"#,
    ])
    func optionalCatalogMetadataAbsentOrNull(json: String) throws {
        let page = try JSONDecoder().decode(CatalogPage.self, from: Data(json.utf8))
        #expect(page == CatalogPage(provider: "future", voices: [CatalogVoice(id: "future-voice", name: "Future")]))
    }

    @Test func unknownProviderModelAndVoiceIDsDecodeVerbatim() throws {
        let json = #"""
        {"effective":{"provider":"future-provider","model":"Future-Model","voice":"Future-Voice"},
         "saved":{"provider":"future-provider","model":"Future-Model","voice":"Future-Voice"},
         "providers":[{"id":"future-provider","name":"Future","available":true,"models":["Future-Model"],
                       "default":{"model":"Future-Model","voice":"Future-Voice"}}],"newMetadata":true}
        """#
        let view = try JSONDecoder().decode(TTSView.self, from: Data(json.utf8))
        #expect(view.effective == TTSChoice(provider: "future-provider", model: "Future-Model", voice: "Future-Voice"))
        #expect(view.saved == SavedTTSChoice(provider: "future-provider", model: "Future-Model", voice: "Future-Voice"))
        #expect(view.providers == [TTSProvider(id: "future-provider", name: "Future", available: true,
                                              models: ["Future-Model"], default: TTSDefaults(model: "Future-Model", voice: "Future-Voice"))])
        #expect(try JSONDecoder().decode(TTSChoice.self, from: Data(#"{"provider":"future-provider"}"#.utf8))
                == TTSChoice(provider: "future-provider"))
    }

    @Test func missingRequiredCatalogFieldsFailDecoding() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CatalogPage.self, from: Data(#"{"provider":"gemini","voices":[{"id":"voice"}]}"#.utf8))
        }
    }

    @Test func resetRequestHasExactBody() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = try line.ttsPatchRequest(.reset)
        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == Data(#"{"reset":true}"#.utf8))
        #expect(request.url?.path == "/voice/tts")
        #expect(try formQuery(request) == ["t": "fake"])
    }

    @Test(arguments: [
        TTSChoice(provider: "gemini"),
        TTSChoice(provider: "gemini", model: "future-model"),
        TTSChoice(provider: "gemini", voice: "future-voice"),
        TTSChoice(provider: "future", model: "Future-Model", voice: "Future-Voice"),
    ])
    func choiceRequestExcludesResetAndNilOptionals(choice: TTSChoice) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = try line.ttsPatchRequest(.choice(choice))
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        var expected = ["provider": choice.provider]
        expected["model"] = choice.model
        expected["voice"] = choice.voice
        #expect(object == expected)
        #expect(object["reset"] == nil)
        #expect(try JSONDecoder().decode(TTSChoice.self, from: body) == choice)
    }

    @Test func sendsExactly1024BytePatch() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let patch = TTSPatch.choice(TTSChoice(provider: "gemini", voice: boundaryVoice(bytes: 1024)))
        let request = try line.ttsPatchRequest(patch)
        let body = try #require(request.httpBody)
        #expect(body.count == 1024)
        #expect(String(decoding: body, as: UTF8.self).count < body.count)
        #expect(try JSONDecoder().decode(TTSChoice.self, from: body) == TTSChoice(provider: "gemini", voice: boundaryVoice(bytes: 1024)))
    }

    @Test func refusesExactly1025BytePatchWithByteCount() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let patch = TTSPatch.choice(TTSChoice(provider: "gemini", voice: boundaryVoice(bytes: 1025)))
        #expect(try JSONEncoder().encode(patch).count == 1025)
        #expect(throws: TTSPatchError.bodyTooLarge(bytes: 1025)) {
            try line.ttsPatchRequest(patch)
        }
    }

    @Test func refusesOversizedVoiceID() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let patch = TTSPatch.choice(TTSChoice(provider: "gemini", voice: String(repeating: "a", count: 1100)))
        let bytes = try JSONEncoder().encode(patch).count
        #expect(throws: TTSPatchError.bodyTooLarge(bytes: bytes)) {
            try line.ttsPatchRequest(patch)
        }
    }

    @Test(arguments: ["a b", "a&b", "a=b", "a+b&c=d", "caf\u{E9} \u{65E5}\u{672C}", "a%2Bb#c?d"])
    func queryEscapingPreservesSearch(q: String) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = line.voicesRequest(provider: "gemini", q: q, language: nil, cursor: nil, limit: 25)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/voice/voices")
        #expect(try formQuery(request) == ["t": "fake", "provider": "gemini", "q": q, "limit": "25"])
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedQuery?.contains("+") == false)
        if q.contains("+") { #expect(components.percentEncodedQuery?.contains("%2B") == true) }
    }

    @Test func queryEscapingPreservesAllFiltersAndProvider() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let request = line.voicesRequest(provider: "future+provider", q: "a+b&c=d", language: "en+US", cursor: "next+/=&", limit: 1)
        #expect(try formQuery(request) == ["t": "fake", "provider": "future+provider", "q": "a+b&c=d",
                                          "language": "en+US", "cursor": "next+/=&", "limit": "1"])
    }

    @Test func httpVoiceRequestsPreserveEncodedToken() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake%2B%26%3D"))
        for request in [line.ttsRequest, try line.ttsPatchRequest(.reset),
                        line.voicesRequest(provider: "gemini", q: nil, language: nil, cursor: nil, limit: 10)] {
            #expect(try formQuery(request)["t"] == "fake+&=")
        }
    }

    @Test func queryNilFiltersAreAbsentAndEmptyFiltersRemainEmpty() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let absent = line.voicesRequest(provider: "gemini", q: nil, language: nil, cursor: nil, limit: 100)
        #expect(try formQuery(absent) == ["t": "fake", "provider": "gemini", "limit": "100"])
        let empty = line.voicesRequest(provider: "gemini", q: "", language: "", cursor: "", limit: 100)
        #expect(try formQuery(empty) == ["t": "fake", "provider": "gemini", "q": "", "language": "", "cursor": "", "limit": "100"])
    }

    @Test(arguments: [511, 512, 513, 600])
    func queryFiltersClampTo512UTF16Units(count: Int) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let input = String(repeating: "a", count: count)
        let expected = String(repeating: "a", count: min(count, 512))
        let query = try formQuery(line.voicesRequest(provider: "gemini", q: input, language: input, cursor: input, limit: 10))
        for name in ["q", "language", "cursor"] { #expect(query[name] == expected) }
    }

    @Test func queryFiltersClampCombiningScalarsByUTF16Length() throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let input = String(repeating: "e\u{301}", count: 600)
        let expected = String(repeating: "e\u{301}", count: 256)
        let query = try formQuery(line.voicesRequest(provider: "gemini", q: input, language: input, cursor: input, limit: 10))
        for name in ["q", "language", "cursor"] {
            #expect(query[name] == expected)
            #expect(query[name]?.utf16.count == 512)
        }
    }

    @Test(arguments: [510, 511, 512])
    func queryFiltersNeverSplitSupplementaryScalar(prefixLength: Int) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let prefix = String(repeating: "a", count: prefixLength)
        let input = prefix + "\u{1F600}z"
        let expected = prefixLength == 510 ? prefix + "\u{1F600}" : prefix
        let query = try formQuery(line.voicesRequest(provider: "gemini", q: input, language: input, cursor: input, limit: 10))
        for name in ["q", "language", "cursor"] {
            #expect(query[name] == expected)
            #expect(try #require(query[name]).utf16.count <= 512)
        }
    }

    @Test(arguments: [(Int.min, "1"), (-1, "1"), (0, "1"), (1, "1"), (50, "50"), (100, "100"), (101, "100"), (Int.max, "100")])
    func queryLimitClampsToOneThrough100(limit: Int, expected: String) throws {
        let line = try #require(VoiceLine(callLink: "https://lines.example/voice?t=fake"))
        let query = try formQuery(line.voicesRequest(provider: "gemini", q: nil, language: nil, cursor: nil, limit: limit))
        #expect(query["limit"] == expected)
    }

    @Test(arguments: ["invalid", "tts_invalid"])
    func mapsInvalidJSONErrors(error: String) {
        let json = "{\"error\":\"\(error)\",\"field\":\"model\"}"
        #expect(TTSServiceFailure(status: 400, body: Data(json.utf8)) == .invalid(field: "model"))
    }

    @Test func mapsBadRequest400AndUpstream502() {
        #expect(TTSServiceFailure(status: 400, body: Data(#"{"error":"bad_request"}"#.utf8)) == .badRequest)
        #expect(TTSServiceFailure(status: 502, body: Data(#"{"error":"upstream"}"#.utf8)) == .upstream)
    }

    @Test(arguments: [400, 403, 404, 405, 500, 502, 503])
    func knownJSONErrorsTakePrecedenceOverStatus(status: Int) {
        let cases: [(String, TTSServiceFailure)] = [
            (#"{"error":"tts_invalid","field":"provider"}"#, .invalid(field: "provider")),
            (#"{"error":"invalid","field":"voice"}"#, .invalid(field: "voice")),
            (#"{"error":"provider_unavailable","provider":"future"}"#, .providerUnavailable(provider: "future")),
            (#"{"error":"bad_request"}"#, .badRequest),
            (#"{"error":"upstream"}"#, .upstream),
        ]
        for (json, expected) in cases {
            #expect(TTSServiceFailure(status: status, body: Data(json.utf8)) == expected)
        }
    }

    @Test(arguments: ["", ",\"field\":null,\"provider\":null", ",\"field\":42,\"provider\":{}"])
    func missingNullOrMalformedErrorMetadataKeepsKnownError(metadata: String) {
        let cases: [(String, TTSServiceFailure)] = [
            ("invalid", .invalid(field: "tts")), ("tts_invalid", .invalid(field: "tts")),
            ("provider_unavailable", .providerUnavailable(provider: "voice")),
            ("bad_request", .badRequest), ("upstream", .upstream),
        ]
        for (error, expected) in cases {
            let json = "{\"error\":\"\(error)\"\(metadata)}"
            #expect(TTSServiceFailure(status: 403, body: Data(json.utf8)) == expected)
        }
    }

    @Test func mapsPlainText503VoiceNotRunning() {
        #expect(TTSServiceFailure(status: 503, body: Data(" \nVoice is not running\r\n".utf8)) == .providerUnavailable(provider: "voice"))
        #expect(TTSServiceFailure(status: 503, body: Data("Other refusal".utf8)) == .refused(status: 503, body: "Other refusal"))
    }

    @Test(arguments: [405, 500])
    func mapsPlainText405And500ToRefused(status: Int) {
        #expect(TTSServiceFailure(status: status, body: Data(" \nRequest refused\t".utf8)) == .refused(status: status, body: "Request refused"))
    }

    @Test func mapsForbidden403AndMissingRoute404() {
        #expect(TTSServiceFailure(status: 403, body: Data("Unknown call link".utf8)) == .forbidden)
        #expect(TTSServiceFailure(status: 404, body: Data("Not found".utf8)) == .noRoute)
        #expect(TTSServiceFailure.forbidden.message == "Access lost. Check this line's call link in Settings.")
    }

    @Test(arguments: [#"{"error":"future"}"#, #"{"error":42}"#, #"{"field":"voice"}"#, "{", ""])
    func unknownOrMalformedErrorJSONFallsBackToStatus(json: String) {
        let body = Data(json.utf8)
        #expect(TTSServiceFailure(status: 403, body: body) == .forbidden)
        #expect(TTSServiceFailure(status: 404, body: body) == .noRoute)
        #expect(TTSServiceFailure(status: 500, body: body) == .refused(status: 500, body: json))
    }

    @Test(arguments: [URLError.Code.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                      .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed])
    func transportTimeoutOfflineAndConnectionErrorsAreUnreachable(code: URLError.Code) {
        #expect(TTSServiceFailure(transportError: URLError(code)) == .unreachable)
    }

    @Test func otherTransportErrorsRetainDetailWithoutDisplayingIt() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private transport detail"])
        #expect(TTSServiceFailure(transportError: error) == .transport("private transport detail"))
        let cancelled = URLError(.cancelled)
        #expect(TTSServiceFailure(transportError: cancelled) == .transport(cancelled.localizedDescription))
    }

    @Test func messagesNeverExposeURLHostOrToken() throws {
        let detail = "https://private.invalid/path?credential=synthetic-token"
        let failures: [TTSServiceFailure] = [
            .invalid(field: detail), .providerUnavailable(provider: detail), .badRequest, .upstream,
            .forbidden, .noRoute, .unreachable, .transport(detail), .malformed, .refused(status: 500, body: detail),
            TTSServiceFailure(status: 403, body: Data(detail.utf8)),
            TTSServiceFailure(transportError: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])),
        ]
        for failure in failures {
            #expect(!failure.message.isEmpty)
            #expect(!failure.message.contains("https://"))
            #expect(!failure.message.contains("private.invalid"))
            #expect(!failure.message.contains("synthetic-token"))
        }
        let body = try JSONEncoder().encode(["error": "invalid", "field": detail])
        let invalid = TTSServiceFailure(status: 400, body: body)
        #expect(invalid == .invalid(field: detail))
        #expect(invalid.message == "The selected voice setting is not valid. Choose another and try again.")
    }

    @Test(arguments: ["provider", "model", "voice"])
    func invalidMessagesRetainKnownFieldLabels(field: String) {
        #expect(TTSServiceFailure.invalid(field: field).message == "The selected \(field) is not valid. Choose another and try again.")
    }

    private func formQuery(_ request: URLRequest) throws -> [String: String] {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try #require(components.percentEncodedQuery)
        var result: [String: String] = [:]
        for item in query.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            try #require(pair.count == 2)
            let name = try #require(String(pair[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            let value = try #require(String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
            #expect(result[name] == nil)
            result[name] = value
        }
        return result
    }

    private func boundaryVoice(bytes: Int) -> String {
        let overhead = Data(#"{"provider":"gemini","voice":""}"#.utf8).count
        return "\u{E9}" + String(repeating: "a", count: bytes - overhead - 2)
    }
}
