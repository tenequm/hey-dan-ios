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

/// Whether the provider named a voice: `unavailable` means it certainly does not have it, `lookupFailed` that it
/// could not be asked.
public enum VoiceStatus: String, Sendable {
    case resolved, unavailable
    case lookupFailed = "lookup_failed"
}

/// The server's names for one choice. Every field is optional and decodes on its own, so a server that sends less,
/// or a value this app cannot read, still decodes the rest.
public struct ChoiceDetails: Decodable, Sendable, Equatable {
    public let provider: String?
    public let providerName: String?
    public let model: String?
    public let modelName: String?
    public let voice: String?
    public let voiceName: String?
    public let language: String?
    public let gender: String?
    public let preview: URL?
    /// Nil when none was given or this app does not know it.
    public let status: VoiceStatus?

    public init(provider: String? = nil, providerName: String? = nil, model: String? = nil, modelName: String? = nil,
                voice: String? = nil, voiceName: String? = nil, language: String? = nil, gender: String? = nil,
                preview: URL? = nil, status: VoiceStatus? = nil) {
        self.provider = provider
        self.providerName = providerName
        self.model = model
        self.modelName = modelName
        self.voice = voice
        self.voiceName = voiceName
        self.language = language
        self.gender = gender
        self.preview = preview
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case provider, providerName, model, modelName, voice, voiceName, language, gender, preview, status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
        provider = text(.provider)
        providerName = text(.providerName)
        model = text(.model)
        modelName = text(.modelName)
        voice = text(.voice)
        voiceName = text(.voiceName)
        language = text(.language)
        gender = text(.gender)
        preview = try? container.decodeIfPresent(URL.self, forKey: .preview)
        status = text(.status).flatMap(VoiceStatus.init(rawValue:))
    }
}

/// What a label says for a voice: the server's name for it, or why there is none.
public enum VoiceLabel: Sendable, Equatable {
    case named(String)
    /// The provider says the voice does not exist.
    case unavailable
    /// The provider could not be asked; asking again may name it.
    case lookupFailed
    /// The provider has the voice but gave it no name; asking again will not change that.
    case unnamed
    /// A server from before voice names sent no details: a generic label, never the id.
    case noDetails(providerDefault: Bool)

    public init(_ details: ChoiceDetails?, providerDefault: Bool = false) {
        guard let details else {
            self = .noDetails(providerDefault: providerDefault)
            return
        }
        if details.status == .unavailable {
            self = .unavailable
        } else if let name = details.voiceName {
            self = .named(name)
        } else {
            self = details.status == .resolved ? .unnamed : .lookupFailed
        }
    }

    public var title: String {
        switch self {
        case let .named(name): name
        case .unavailable: "Voice no longer available"
        case .lookupFailed, .unnamed: "Name unavailable"
        case let .noDetails(providerDefault): providerDefault ? "Provider default voice" : "Selected voice"
        }
    }
}

public struct TTSProvider: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let available: Bool
    public let models: [String]
    public let `default`: TTSDefaults
    public let modelNames: [String: String]?
    public let defaultDetails: ChoiceDetails?

    public init(id: String, name: String, available: Bool, models: [String], default: TTSDefaults,
                modelNames: [String: String]? = nil, defaultDetails: ChoiceDetails? = nil) {
        self.id = id
        self.name = name
        self.available = available
        self.models = models
        self.default = `default`
        self.modelNames = modelNames
        self.defaultDetails = defaultDetails
    }
}

public struct TTSDetails: Decodable, Sendable, Equatable {
    public let saved: ChoiceDetails?
    public let effective: ChoiceDetails?

    public init(saved: ChoiceDetails? = nil, effective: ChoiceDetails? = nil) {
        self.saved = saved
        self.effective = effective
    }
}

public struct TTSView: Decodable, Sendable, Equatable {
    public let effective: TTSChoice
    public let saved: SavedTTSChoice
    public let providers: [TTSProvider]
    public let details: TTSDetails?

    public init(effective: TTSChoice, saved: SavedTTSChoice, providers: [TTSProvider], details: TTSDetails? = nil) {
        self.effective = effective
        self.saved = saved
        self.providers = providers
        self.details = details
    }
}

public extension TTSView {
    /// Whether this view shows `patch` saved. The server fills an omitted model or voice with the provider default.
    /// A reset writes the line's default, which the server does not report, so only an older server's empty row
    /// proves one: a changed saved choice may be another client's save.
    func confirms(_ patch: TTSPatch) -> Bool {
        switch patch {
        case .reset:
            return saved.isEmpty
        case let .choice(choice):
            let fallback = providers.first { $0.id == choice.provider }?.default
            return saved.provider == choice.provider
                && (saved.model == choice.model || (choice.model == nil && saved.model == fallback?.model))
                && (saved.voice == choice.voice || (choice.voice == nil && saved.voice == fallback?.voice))
        }
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

public struct VoiceLineCatalogVoice: Decodable, Sendable, Equatable {
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
    public let voices: [VoiceLineCatalogVoice]
    public let next: String?

    public init(provider: String, voices: [VoiceLineCatalogVoice], next: String? = nil) {
        self.provider = provider
        self.voices = voices
        self.next = next
    }
}

public enum TTSServiceFailure: Error, Sendable, Equatable {
    case server(status: Int, code: String, message: String)
    /// Stopped on this phone before any request: the device key is locked or the host is unpaired.
    case local(code: String, message: String)
    case pairedTransport
    case invalid(field: String)
    case malformed

    public var message: String {
        switch self {
        case .server(_, _, let message), .local(_, let message): message
        case .pairedTransport: "Could not reach the voice service. Check your internet connection and try again."
        case let .invalid(field) where ["provider", "model", "voice"].contains(field):
            "The selected \(field) is not valid. Choose another and try again."
        case .invalid: "The selected voice setting is not valid. Choose another and try again."
        case .malformed: "The host answered with something this app does not understand."
        }
    }

}
