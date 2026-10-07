import Foundation

/// The voice lines saved on this phone, each named for the agent that answers it, and the one a call goes to
/// when nothing names another.
public struct VoiceLines: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        /// Random, never derived from the link: shortcuts keep it, and they sync through iCloud.
        public let id: UUID
        public let line: VoiceLine
        /// Who answers, as the host names it; nil until the host has said.
        public internal(set) var agent: String?
        /// What the app calls the agent: its name, or a stand-in until the host said it.
        public var name: String { agent ?? VoiceLines.unnamedAgent }

        public init(id: UUID = UUID(), line: VoiceLine, agent: String? = nil) {
            self.id = id
            self.line = line
            self.agent = Self.cleaned(agent)
        }

        private enum CodingKeys: String, CodingKey { case id, link, agent }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let link = try container.decode(String.self, forKey: .link)
            guard let line = VoiceLine(callLink: link) else {
                throw DecodingError.dataCorruptedError(forKey: .link, in: container, debugDescription: "not a call link")
            }
            self.init(
                id: try container.decode(UUID.self, forKey: .id), line: line,
                agent: try container.decodeIfPresent(String.self, forKey: .agent)
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(line.callLink, forKey: .link)
            try container.encodeIfPresent(agent, forKey: .agent)
        }

        static func cleaned(_ agent: String?) -> String? {
            guard let agent = agent?.trimmingCharacters(in: .whitespacesAndNewlines), !agent.isEmpty else { return nil }
            return agent
        }
    }

    public static let unnamedAgent = "your agent"

    public private(set) var entries: [Entry]
    private var selectedID: UUID?
    /// Stored entries this version cannot read, kept as they were: every save writes them back, so nothing a newer
    /// version (or a damaged write) left behind is lost.
    private var unreadable: [JSON] = []

    public init(entries: [Entry] = [], selectedID: UUID? = nil) {
        self.entries = entries
        self.selectedID = selectedID
    }

    /// How many stored entries this version cannot read.
    public var unreadableCount: Int { unreadable.count }

    private enum CodingKeys: String, CodingKey { case entries, selectedID }

    /// Stored lines read one by one: an entry this version cannot read stays aside, never the others with it. Throws
    /// only when there is no list of lines at all.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var entries: [Entry] = []
        for stored in try container.decode([Stored].self, forKey: .entries) {
            switch stored {
            case let .entry(entry): entries.append(entry)
            case let .unreadable(json): unreadable.append(json)
            }
        }
        self.entries = entries
        selectedID = try? container.decodeIfPresent(UUID.self, forKey: .selectedID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries.map(Stored.entry) + unreadable.map(Stored.unreadable), forKey: .entries)
        try container.encodeIfPresent(selectedID, forKey: .selectedID)
    }

    private enum Stored: Codable {
        case entry(Entry)
        case unreadable(JSON)

        init(from decoder: any Decoder) throws {
            if let entry = try? Entry(from: decoder) { self = .entry(entry) } else { self = .unreadable(try JSON(from: decoder)) }
        }

        func encode(to encoder: any Encoder) throws {
            switch self {
            case let .entry(entry): try entry.encode(to: encoder)
            case let .unreadable(json): try json.encode(to: encoder)
            }
        }
    }

    /// Any JSON value, kept as it was read.
    private indirect enum JSON: Codable, Sendable, Equatable {
        case null
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case string(String)
        case array([JSON])
        case object([String: JSON])

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .null
            } else if let bool = try? value.decode(Bool.self) {
                self = .bool(bool)
            } else if let int = try? value.decode(Int64.self) {
                self = .int(int)
            } else if let double = try? value.decode(Double.self) {
                self = .double(double)
            } else if let string = try? value.decode(String.self) {
                self = .string(string)
            } else if let array = try? value.decode([JSON].self) {
                self = .array(array)
            } else {
                self = .object(try value.decode([String: JSON].self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .null: try value.encodeNil()
            case let .bool(bool): try value.encode(bool)
            case let .int(int): try value.encode(int)
            case let .double(double): try value.encode(double)
            case let .string(string): try value.encode(string)
            case let .array(array): try value.encode(array)
            case let .object(object): try value.encode(object)
            }
        }
    }

    /// The single call link older versions kept, as the one saved line; its agent is learned later.
    public init(legacyLink: String) {
        self.init()
        if let line = VoiceLine(callLink: legacyLink) { add(line) }
    }

    /// The line a call goes to unless one is named: the picked one, else the first.
    public var selected: Entry? { entries.first { $0.id == selectedID } ?? entries.first }

    public func entry(_ id: UUID) -> Entry? { entries.first { $0.id == id } }

    public func id(of line: VoiceLine) -> UUID? { entries.first { $0.line == line }?.id }

    /// Saves a line, or finds it when the same link is saved already; either way it becomes the picked one.
    @discardableResult
    public mutating func add(_ line: VoiceLine, agent: String? = nil) -> UUID {
        let id = id(of: line) ?? {
            let entry = Entry(line: line)
            entries.append(entry)
            return entry.id
        }()
        if let agent { name(id, agent: agent) }
        selectedID = id
        return id
    }

    public mutating func select(_ id: UUID) {
        guard entry(id) != nil else { return }
        selectedID = id
    }

    /// Forgets a line; when it was the picked one, the first left takes over.
    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if selectedID == id { selectedID = entries.first?.id }
    }

    /// Names the agent that answers a line: false when that changed nothing.
    @discardableResult
    public mutating func name(_ id: UUID, agent: String) -> Bool {
        guard let agent = Entry.cleaned(agent), let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].agent != agent
        else { return false }
        entries[index].agent = agent
        return true
    }
}

/// The host's answer to `VoiceLine.infoRequest`: who answers the line, asked without starting a call.
public struct LineInfo: Decodable, Sendable, Equatable {
    public let agent: String

    public init(status: Int, body: Data) throws(CallFailure) {
        self = try hostAnswer(status: status, body: body)
    }
}

extension VoiceLine {
    /// Asks the host who answers this line (`LineInfo`); starts no call.
    public var infoRequest: URLRequest { URLRequest(url: endpoint("info")) }
}
