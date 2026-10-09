import Foundation

public struct TTSChoice: Codable, Sendable, Equatable {
    public let provider: String
    public let model: String?
    public let voice: String?

    public init(provider: String, model: String? = nil, voice: String? = nil) {
        self.provider = provider
        self.model = model
        self.voice = voice
    }
}

public struct SavedTTSChoice: Decodable, Sendable, Equatable {
    public let provider: String?
    public let model: String?
    public let voice: String?

    public init(provider: String? = nil, model: String? = nil, voice: String? = nil) {
        self.provider = provider
        self.model = model
        self.voice = voice
    }

    public var isEmpty: Bool { provider == nil && model == nil && voice == nil }
}

public struct TTSDefaults: Decodable, Sendable, Equatable {
    public let model: String
    public let voice: String

    public init(model: String, voice: String) {
        self.model = model
        self.voice = voice
    }
}

public struct TTSProvider: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let available: Bool
    public let models: [String]
    public let `default`: TTSDefaults

    public init(id: String, name: String, available: Bool, models: [String], default: TTSDefaults) {
        self.id = id
        self.name = name
        self.available = available
        self.models = models
        self.default = `default`
    }
}

public struct TTSView: Decodable, Sendable, Equatable {
    public let effective: TTSChoice
    public let saved: SavedTTSChoice
    public let providers: [TTSProvider]

    public init(effective: TTSChoice, saved: SavedTTSChoice, providers: [TTSProvider]) {
        self.effective = effective
        self.saved = saved
        self.providers = providers
    }
}

public enum TTSPatch: Encodable, Sendable, Equatable {
    case choice(TTSChoice)
    case reset

    private enum CodingKeys: String, CodingKey { case reset }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .choice(choice): try choice.encode(to: encoder)
        case .reset:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(true, forKey: .reset)
        }
    }
}

public struct CatalogVoice: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let language: String?
    public let gender: String?
    public let description: String?
    public let preview: URL?

    public init(id: String, name: String, language: String? = nil, gender: String? = nil, description: String? = nil, preview: URL? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.gender = gender
        self.description = description
        self.preview = preview
    }
}

public struct CatalogPage: Decodable, Sendable, Equatable {
    public let provider: String
    public let voices: [CatalogVoice]
    public let next: String?

    public init(provider: String, voices: [CatalogVoice], next: String? = nil) {
        self.provider = provider
        self.voices = voices
        self.next = next
    }
}

public enum TTSPatchError: Error, Sendable, Equatable {
    case bodyTooLarge(bytes: Int)
}

public enum TTSServiceFailure: Error, Sendable, Equatable {
    case invalid(field: String)
    case providerUnavailable(provider: String)
    case badRequest
    case upstream
    case forbidden
    case noRoute
    case unreachable
    case transport(String)
    case malformed
    case refused(status: Int, body: String)

    public init(status: Int, body: Data) {
        if let failure = try? JSONDecoder().decode(ServiceError.self, from: body) {
            switch failure.error {
            case "tts_invalid", "invalid":
                self = .invalid(field: failure.field ?? "tts")
                return
            case "provider_unavailable":
                self = .providerUnavailable(provider: failure.provider ?? "voice")
                return
            case "bad_request":
                self = .badRequest
                return
            case "upstream":
                self = .upstream
                return
            default: break
            }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 403: self = .forbidden
        case 404: self = .noRoute
        case 503 where text == "Voice is not running": self = .providerUnavailable(provider: "voice")
        default: self = .refused(status: status, body: text)
        }
    }

    public init(transportError error: any Error) {
        let unreachable: [URLError.Code] = [
            .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
            .dnsLookupFailed, .secureConnectionFailed,
        ]
        if let error = error as? URLError, unreachable.contains(error.code) {
            self = .unreachable
        } else {
            self = .transport(error.localizedDescription)
        }
    }

    public var message: String {
        switch self {
        case let .invalid(field) where ["provider", "model", "voice"].contains(field):
            "The selected \(field) is not valid. Choose another and try again."
        case .invalid: "The selected voice setting is not valid. Choose another and try again."
        case .providerUnavailable: "That voice provider is not configured on the server. Choose another provider."
        case .badRequest: "The voice line could not understand this request."
        case .upstream: "The voice provider could not load the catalog. Try again."
        case .forbidden: "Access lost. Check this line's call link in Settings."
        case .noRoute: "This voice line does not support voice settings."
        case .unreachable: "Can't reach the voice line. Check that Tailscale is connected, then try again."
        case .transport: "Could not reach the voice line. Try again."
        case .malformed: "The voice line answered with something this app does not understand."
        case let .refused(status, _): "The voice line refused the request (HTTP \(status))."
        }
    }

    private struct ServiceError: Decodable {
        let error: String
        let field: String?
        let provider: String?

        private enum CodingKeys: String, CodingKey { case error, field, provider }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try container.decode(String.self, forKey: .error)
            field = try? container.decode(String.self, forKey: .field)
            provider = try? container.decode(String.self, forKey: .provider)
        }
    }
}

public extension VoiceLine {
    var ttsRequest: URLRequest {
        var components = URLComponents(url: endpoint("tts"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return URLRequest(url: components.url!)
    }

    func ttsPatchRequest(_ patch: TTSPatch) throws(TTSPatchError) -> URLRequest {
        let body = Data(rpcPayload(patch).utf8)
        guard body.count <= 1024 else { throw .bodyTooLarge(bytes: body.count) }
        var request = ttsRequest
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    func voicesRequest(provider: String, q: String?, language: String?, cursor: String?, limit: Int) -> URLRequest {
        var components = URLComponents(url: endpoint("voices"), resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "provider", value: provider))
        for (name, value) in [("q", q), ("language", language), ("cursor", cursor)] {
            if let value {
                var utf16Length = 0
                let scalars = value.unicodeScalars.prefix { scalar in
                    let length = scalar.value > 0xFFFF ? 2 : 1
                    guard utf16Length + length <= 512 else { return false }
                    utf16Length += length
                    return true
                }
                query.append(URLQueryItem(name: name, value: String(String.UnicodeScalarView(scalars))))
            }
        }
        query.append(URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))))
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return URLRequest(url: components.url!)
    }
}
