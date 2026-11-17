import Foundation
import CryptoKit

nonisolated public enum Role: Sendable, Equatable, Codable {
    case user, agent, host
    case unknown(String)
    public init(_ value: String) {
        switch value {
        case "user": self = .user
        case "agent": self = .agent
        case "host": self = .host
        default: self = .unknown(value)
        }
    }
    public var rawValue: String {
        switch self {
        case .user: "user"
        case .agent: "agent"
        case .host: "host"
        case .unknown(let value): value
        }
    }
    public init(from decoder: any Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated public enum Voice: Sendable, Equatable, Codable {
    case caller, spoken
    case unknown(String)
    public init(_ value: String) {
        switch value {
        case "caller": self = .caller
        case "spoken": self = .spoken
        default: self = .unknown(value)
        }
    }
    public var rawValue: String {
        switch self {
        case .caller: "caller"
        case .spoken: "spoken"
        case .unknown(let value): value
        }
    }
    public init(from decoder: any Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated public enum Kind: Sendable, Equatable, Codable {
    case conversation, message, question, status, badge, synchronized, image, file, daily, duration
    case unknown(String)
    public init(_ value: String) {
        switch value {
        case "conversation": self = .conversation
        case "message": self = .message
        case "question": self = .question
        case "badge": self = .badge
        case "status": self = .status
        case "synchronized": self = .synchronized
        case "image": self = .image
        case "file": self = .file
        case "daily": self = .daily
        case "duration": self = .duration
        default: self = .unknown(value)
        }
    }
    public var rawValue: String {
        switch self {
        case .conversation: "conversation"
        case .message: "message"
        case .question: "question"
        case .badge: "badge"
        case .status: "status"
        case .synchronized: "synchronized"
        case .image: "image"
        case .file: "file"
        case .daily: "daily"
        case .duration: "duration"
        case .unknown(let value): value
        }
    }
    public init(from decoder: any Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated public enum State: Sendable, Equatable, Codable {
    case open, answered, expired, idle, working, waiting
    case unknown(String)
    public init(_ value: String) {
        switch value {
        case "open": self = .open
        case "answered": self = .answered
        case "expired": self = .expired
        case "idle": self = .idle
        case "working": self = .working
        case "waiting": self = .waiting
        default: self = .unknown(value)
        }
    }
    public var rawValue: String {
        switch self {
        case .open: "open"
        case .answered: "answered"
        case .expired: "expired"
        case .idle: "idle"
        case .working: "working"
        case .waiting: "waiting"
        case .unknown(let value): value
        }
    }
    public init(from decoder: any Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated public enum Delivery: Sendable, Equatable, Codable {
    case stored, routed, reached, failed, outcomeUnknown
    case unknown(String)
    public init(_ value: String) {
        switch value {
        case "stored": self = .stored
        case "routed": self = .routed
        case "reached": self = .reached
        case "unknown": self = .outcomeUnknown
        case "failed": self = .failed
        default: self = .unknown(value)
        }
    }
    public var rawValue: String {
        switch self {
        case .stored: "stored"
        case .routed: "routed"
        case .reached: "reached"
        case .outcomeUnknown: "unknown"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }
    public init(from decoder: any Decoder) throws { self.init(try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated public struct Agent: Sendable, Equatable, Codable {
    public var `id`: String
    public var `name`: String
    public init(`id`: String, `name`: String) {
        self.`id` = `id`
        self.`name` = `name`
    }
}

nonisolated public struct AppVersion: Sendable, Equatable, Codable {
    public var `version`: String
    public var `build`: String
    public var `os`: String
    public init(`version`: String, `build`: String, `os`: String) {
        self.`version` = `version`
        self.`build` = `build`
        self.`os` = `os`
    }
}

nonisolated public struct ErrorBody: Sendable, Equatable, Codable {
    public var `error`: String
    public var `message`: String
    public var `protocol`: Int?
    public var `serverTime`: Int64?
    public var `retryAfter`: Int?
    public var `fileId`: String?
    public var `maxBytes`: Int64?
    public var `question`: Question?
    public var `provider`: String?
    public var `field`: String?
    public init(`error`: String, `message`: String, `protocol`: Int? = nil, `serverTime`: Int64? = nil, `retryAfter`: Int? = nil, `fileId`: String? = nil, `maxBytes`: Int64? = nil, `question`: Question? = nil, `provider`: String? = nil, `field`: String? = nil) {
        self.`error` = `error`
        self.`message` = `message`
        self.`protocol` = `protocol`
        self.`serverTime` = `serverTime`
        self.`retryAfter` = `retryAfter`
        self.`fileId` = `fileId`
        self.`maxBytes` = `maxBytes`
        self.`question` = `question`
        self.`provider` = `provider`
        self.`field` = `field`
    }
}

nonisolated public struct HelloResponse: Sendable, Equatable, Codable {
    public var `protocol`: Int
    public var `minProtocol`: Int
    public var `voiceProtocol`: Int
    public var `features`: [String]
    public var `serverTime`: Int64
    public init(`protocol`: Int, `minProtocol`: Int, `voiceProtocol`: Int, `features`: [String], `serverTime`: Int64) {
        self.`protocol` = `protocol`
        self.`minProtocol` = `minProtocol`
        self.`voiceProtocol` = `voiceProtocol`
        self.`features` = `features`
        self.`serverTime` = `serverTime`
    }
}

nonisolated public struct PairRequest: Sendable, Equatable, Codable {
    public var `code`: String
    public var `publicKey`: String
    public var `deviceName`: String
    public var `proof`: String
    public var `app`: AppVersion
    public init(`code`: String, `publicKey`: String, `deviceName`: String, `proof`: String, `app`: AppVersion) {
        self.`code` = `code`
        self.`publicKey` = `publicKey`
        self.`deviceName` = `deviceName`
        self.`proof` = `proof`
        self.`app` = `app`
    }
}

nonisolated public struct PairResponse: Sendable, Equatable, Codable {
    public var `deviceId`: String
    public var `userName`: String
    public var `agents`: [Agent]
    public var `protocol`: Int
    public var `serverTime`: Int64
    public init(`deviceId`: String, `userName`: String, `agents`: [Agent], `protocol`: Int, `serverTime`: Int64) {
        self.`deviceId` = `deviceId`
        self.`userName` = `userName`
        self.`agents` = `agents`
        self.`protocol` = `protocol`
        self.`serverTime` = `serverTime`
    }
}

nonisolated public struct LastMessage: Sendable, Equatable, Codable {
    public var `id`: String
    public var `role`: Role
    public var `preview`: String
    public var `at`: Int64
    public init(`id`: String, `role`: Role, `preview`: String, `at`: Int64) {
        self.`id` = `id`
        self.`role` = `role`
        self.`preview` = `preview`
        self.`at` = `at`
    }
}

nonisolated public struct Conversation: Sendable, Equatable, Codable {
    public var `kind`: Kind
    public var `id`: String
    public var `seq`: Int64
    public var `agent`: Agent
    public var `lastMessage`: LastMessage?
    public var `unread`: Int
    public var `readOrder`: Int64
    public var `canCall`: Bool
    public var `callRefusal`: ErrorBody?
    public var `createdAt`: Int64
    public init(`kind`: Kind, `id`: String, `seq`: Int64, `agent`: Agent, `lastMessage`: LastMessage? = nil, `unread`: Int, `readOrder`: Int64, `canCall`: Bool, `callRefusal`: ErrorBody? = nil, `createdAt`: Int64) {
        self.`kind` = `kind`
        self.`id` = `id`
        self.`seq` = `seq`
        self.`agent` = `agent`
        self.`lastMessage` = `lastMessage`
        self.`unread` = `unread`
        self.`readOrder` = `readOrder`
        self.`canCall` = `canCall`
        self.`callRefusal` = `callRefusal`
        self.`createdAt` = `createdAt`
    }
}

nonisolated public struct FileAttachment: Sendable, Equatable, Codable {
    public var `id`: String
    public var `name`: String
    public var `mimeType`: String
    public var `size`: Int64
    public var `kind`: Kind
    public var `width`: Int?
    public var `height`: Int?
    public init(`id`: String, `name`: String, `mimeType`: String, `size`: Int64, `kind`: Kind, `width`: Int? = nil, `height`: Int? = nil) {
        self.`id` = `id`
        self.`name` = `name`
        self.`mimeType` = `mimeType`
        self.`size` = `size`
        self.`kind` = `kind`
        self.`width` = `width`
        self.`height` = `height`
    }
}

nonisolated public struct Reaction: Sendable, Equatable, Codable {
    public var `emoji`: String
    public var `by`: Role
    public init(`emoji`: String, `by`: Role) {
        self.`emoji` = `emoji`
        self.`by` = `by`
    }
}

nonisolated public struct Message: Sendable, Equatable, Codable {
    public var `kind`: Kind
    public var `id`: String
    public var `conversationId`: String
    public var `order`: Int64
    public var `seq`: Int64
    public var `role`: Role
    public var `text`: String
    public var `files`: [FileAttachment]
    public var `reactions`: [Reaction]
    public var `voice`: Voice?
    public var `replyTo`: String?
    public var `clientId`: String?
    public var `delivery`: Delivery?
    public var `deliveryError`: ErrorBody?
    public var `createdAt`: Int64
    public var `editedAt`: Int64?
    public init(`kind`: Kind, `id`: String, `conversationId`: String, `order`: Int64, `seq`: Int64, `role`: Role, `text`: String, `files`: [FileAttachment], `reactions`: [Reaction], `voice`: Voice? = nil, `replyTo`: String? = nil, `clientId`: String? = nil, `delivery`: Delivery? = nil, `deliveryError`: ErrorBody? = nil, `createdAt`: Int64, `editedAt`: Int64? = nil) {
        self.`kind` = `kind`
        self.`id` = `id`
        self.`conversationId` = `conversationId`
        self.`order` = `order`
        self.`seq` = `seq`
        self.`role` = `role`
        self.`text` = `text`
        self.`files` = `files`
        self.`reactions` = `reactions`
        self.`voice` = `voice`
        self.`replyTo` = `replyTo`
        self.`clientId` = `clientId`
        self.`delivery` = `delivery`
        self.`deliveryError` = `deliveryError`
        self.`createdAt` = `createdAt`
        self.`editedAt` = `editedAt`
    }
}

nonisolated public struct QuestionOption: Sendable, Equatable, Codable {
    public var `label`: String
    public var `selectedLabel`: String
    public var `value`: String
    public var `style`: String?
    public init(`label`: String, `selectedLabel`: String, `value`: String, `style`: String?) {
        self.`label` = `label`
        self.`selectedLabel` = `selectedLabel`
        self.`value` = `value`
        self.`style` = `style`
    }
}

nonisolated public struct QuestionAnswer: Sendable, Equatable, Codable {
    public var `value`: String
    public var `label`: String
    public var `at`: Int64
    public init(`value`: String, `label`: String, `at`: Int64) {
        self.`value` = `value`
        self.`label` = `label`
        self.`at` = `at`
    }
}

nonisolated public struct Question: Sendable, Equatable, Codable {
    public var `kind`: Kind
    public var `id`: String
    public var `conversationId`: String
    public var `order`: Int64
    public var `seq`: Int64
    public var `title`: String
    public var `text`: String
    public var `options`: [QuestionOption]
    public var `state`: State
    public var `answer`: QuestionAnswer?
    public var `createdAt`: Int64
    public var `expiresAt`: Int64?
    public init(`kind`: Kind, `id`: String, `conversationId`: String, `order`: Int64, `seq`: Int64, `title`: String, `text`: String, `options`: [QuestionOption], `state`: State, `answer`: QuestionAnswer? = nil, `createdAt`: Int64, `expiresAt`: Int64? = nil) {
        self.`kind` = `kind`
        self.`id` = `id`
        self.`conversationId` = `conversationId`
        self.`order` = `order`
        self.`seq` = `seq`
        self.`title` = `title`
        self.`text` = `text`
        self.`options` = `options`
        self.`state` = `state`
        self.`answer` = `answer`
        self.`createdAt` = `createdAt`
        self.`expiresAt` = `expiresAt`
    }
}

nonisolated public struct Badge: Sendable, Equatable, Codable {
    public var kind: Kind
    public var rev: Int64
    public var unreadTotal: Int
    public init(kind: Kind, rev: Int64, unreadTotal: Int) {
        self.kind = kind
        self.rev = rev
        self.unreadTotal = unreadTotal
    }
}

nonisolated public struct Status: Sendable, Equatable, Codable {
    public var `kind`: Kind
    public var `conversationId`: String
    public var `rev`: Int64
    public var `state`: State
    public var `label`: String?
    public var `at`: Int64
    public init(`kind`: Kind, `conversationId`: String, `rev`: Int64, `state`: State, `label`: String? = nil, `at`: Int64) {
        self.`kind` = `kind`
        self.`conversationId` = `conversationId`
        self.`rev` = `rev`
        self.`state` = `state`
        self.`label` = `label`
        self.`at` = `at`
    }
}

nonisolated public struct ConversationsResponse: Sendable, Equatable, Codable {
    public var `conversations`: [Conversation]
    public var `statuses`: [Status]
    public var `badge`: Badge
    public var `seq`: Int64
    public init(`conversations`: [Conversation], `statuses`: [Status], `badge`: Badge, `seq`: Int64) {
        self.`conversations` = `conversations`
        self.`statuses` = `statuses`
        self.`badge` = `badge`
        self.`seq` = `seq`
    }
}

nonisolated public struct HistoryPage: Sendable, Equatable, Codable {
    public var `items`: [ThreadEntity]
    public var `hasMoreBefore`: Bool
    public var `hasMoreAfter`: Bool
    public init(`items`: [ThreadEntity], `hasMoreBefore`: Bool, `hasMoreAfter`: Bool) {
        self.`items` = `items`
        self.`hasMoreBefore` = `hasMoreBefore`
        self.`hasMoreAfter` = `hasMoreAfter`
    }
}

nonisolated public struct SendRequest: Sendable, Equatable, Codable {
    public var `clientId`: String
    public var `text`: String
    public var `fileIds`: [String]
    public init(`clientId`: String, `text`: String, `fileIds`: [String]) {
        self.`clientId` = `clientId`
        self.`text` = `text`
        self.`fileIds` = `fileIds`
    }
}

nonisolated public struct SendResponse: Sendable, Equatable, Codable {
    public var `message`: Message
    public init(`message`: Message) {
        self.`message` = `message`
    }
}

nonisolated public struct ReadRequest: Sendable, Equatable, Codable {
    public var `order`: Int64
    public init(`order`: Int64) {
        self.`order` = `order`
    }
}

nonisolated public struct ReadResponse: Sendable, Equatable, Codable {
    public var `conversation`: Conversation
    public var `badge`: Badge
    public init(`conversation`: Conversation, `badge`: Badge) {
        self.`conversation` = `conversation`
        self.`badge` = `badge`
    }
}

nonisolated public struct AnswerRequest: Sendable, Equatable, Codable {
    public var `value`: String
    public init(`value`: String) {
        self.`value` = `value`
    }
}

nonisolated public struct AnswerResponse: Sendable, Equatable, Codable {
    public var `question`: Question
    public init(`question`: Question) {
        self.`question` = `question`
    }
}

nonisolated public struct FileInitRequest: Sendable, Equatable, Codable {
    public var `uploadKey`: String
    public var `name`: String
    public var `mimeType`: String
    public var `size`: Int64
    public var `sha256`: String
    public init(`uploadKey`: String, `name`: String, `mimeType`: String, `size`: Int64, `sha256`: String) {
        self.`uploadKey` = `uploadKey`
        self.`name` = `name`
        self.`mimeType` = `mimeType`
        self.`size` = `size`
        self.`sha256` = `sha256`
    }
}

nonisolated public struct FileInitResponse: Sendable, Equatable, Codable {
    public var `fileId`: String
    public var `ticket`: String
    public var `expiresAt`: Int64
    public var `uploadPath`: String
    public var `uploaded`: Bool
    public init(`fileId`: String, `ticket`: String, `expiresAt`: Int64, `uploadPath`: String, `uploaded`: Bool) {
        self.`fileId` = `fileId`
        self.`ticket` = `ticket`
        self.`expiresAt` = `expiresAt`
        self.`uploadPath` = `uploadPath`
        self.`uploaded` = `uploaded`
    }
}

nonisolated public struct TicketClaims: Sendable, Equatable, Codable {
    public var `v`: Int
    public var `purpose`: String
    public var `fileId`: String
    public var `deviceId`: String
    public var `userId`: String
    public var `size`: Int64
    public var `sha256`: String
    public var `exp`: Int64
    public init(`v`: Int, `purpose`: String, `fileId`: String, `deviceId`: String, `userId`: String, `size`: Int64, `sha256`: String, `exp`: Int64) {
        self.`v` = `v`
        self.`purpose` = `purpose`
        self.`fileId` = `fileId`
        self.`deviceId` = `deviceId`
        self.`userId` = `userId`
        self.`size` = `size`
        self.`sha256` = `sha256`
        self.`exp` = `exp`
    }
}

nonisolated public struct CallRequest: Sendable, Equatable, Codable {
    public var `conversationId`: String
    public var `attemptId`: String
    public var `voiceProtocol`: Int
    public var `jev`: Bool?
    public init(`conversationId`: String, `attemptId`: String, `voiceProtocol`: Int, `jev`: Bool? = nil) {
        self.`conversationId` = `conversationId`
        self.`attemptId` = `attemptId`
        self.`voiceProtocol` = `voiceProtocol`
        self.`jev` = `jev`
    }
}

nonisolated public struct CallLimit: Sendable, Equatable, Codable {
    public var `ms`: Int64
    public var `kind`: Kind
    public init(`ms`: Int64, `kind`: Kind) {
        self.`ms` = `ms`
        self.`kind` = `kind`
    }
}

nonisolated public struct CallGrant: Sendable, Equatable, Codable {
    public var `protocol`: Int
    public var `url`: String
    public var `token`: String
    public var `callId`: String
    public var `attemptId`: String
    public var `agent`: String
    public var `chat`: String
    public var `silenceMs`: Int64
    public var `limit`: CallLimit
    public init(`protocol`: Int, `url`: String, `token`: String, `callId`: String, `attemptId`: String, `agent`: String, `chat`: String, `silenceMs`: Int64, `limit`: CallLimit) {
        self.`protocol` = `protocol`
        self.`url` = `url`
        self.`token` = `token`
        self.`callId` = `callId`
        self.`attemptId` = `attemptId`
        self.`agent` = `agent`
        self.`chat` = `chat`
        self.`silenceMs` = `silenceMs`
        self.`limit` = `limit`
    }
}

public typealias CallCancelRequest = CallEndRequest

nonisolated public struct CallEndRequest: Sendable, Equatable, Codable {
    public var `reason`: String
    public init(`reason`: String) {
        self.`reason` = `reason`
    }
}

nonisolated public struct PushTokenRequest: Sendable, Equatable, Codable {
    public var `token`: String
    public var `environment`: String
    public init(`token`: String, `environment`: String) {
        self.`token` = `token`
        self.`environment` = `environment`
    }
}

nonisolated public struct PushAlert: Sendable, Equatable, Codable {
    public var `title`: String
    public var `body`: String
    public init(`title`: String, `body`: String) {
        self.`title` = `title`
        self.`body` = `body`
    }
}

nonisolated public struct PushAPS: Sendable, Equatable, Codable {
    public var `alert`: PushAlert
    public var `threadId`: String
    public var `mutableContent`: Int
    public var `badge`: Int
    public var `sound`: String
    public var `category`: String
    public init(`alert`: PushAlert, `threadId`: String, `mutableContent`: Int, `badge`: Int, `sound`: String, `category`: String) {
        self.`alert` = `alert`
        self.`threadId` = `threadId`
        self.`mutableContent` = `mutableContent`
        self.`badge` = `badge`
        self.`sound` = `sound`
        self.`category` = `category`
    }
    private enum CodingKeys: String, CodingKey {
        case alert, badge, sound, category
        case threadId = "thread-id"
        case mutableContent = "mutable-content"
    }
}

nonisolated public struct PushData: Sendable, Equatable, Codable {
    public var `v`: Int
    public var `c`: String
    public var `m`: String
    public var `k`: Kind
    public var `a`: Agent
    public init(`v`: Int, `c`: String, `m`: String, `k`: Kind, `a`: Agent) {
        self.`v` = `v`
        self.`c` = `c`
        self.`m` = `m`
        self.`k` = `k`
        self.`a` = `a`
    }
}

nonisolated public struct PushPayload: Sendable, Equatable, Codable {
    public var `aps`: PushAPS
    public var `hd`: PushData
    public init(`aps`: PushAPS, `hd`: PushData) {
        self.`aps` = `aps`
        self.`hd` = `hd`
    }
}

nonisolated public struct Synchronized: Sendable, Equatable, Codable {
    public var `seq`: Int64
    public init(`seq`: Int64) {
        self.`seq` = `seq`
    }
}

nonisolated public struct VoiceSelection: Sendable, Equatable, Codable {
    public var `provider`: String
    public var `model`: String
    public var `voice`: String
    public init(`provider`: String, `model`: String, `voice`: String) {
        self.`provider` = `provider`
        self.`model` = `model`
        self.`voice` = `voice`
    }
}

nonisolated public struct SavedVoiceSelection: Sendable, Equatable, Codable {
    public var `provider`: String?
    public var `model`: String?
    public var `voice`: String?
    public init(`provider`: String?, `model`: String?, `voice`: String?) {
        self.`provider` = `provider`
        self.`model` = `model`
        self.`voice` = `voice`
    }
}

nonisolated public struct VoicePatchRequest: Sendable, Equatable, Codable {
    public var `provider`: String?
    public var `model`: String?
    public var `voice`: String?
    public init(`provider`: String? = nil, `model`: String? = nil, `voice`: String? = nil) {
        self.`provider` = `provider`
        self.`model` = `model`
        self.`voice` = `voice`
    }
}

nonisolated public struct VoiceDetails: Sendable, Equatable, Codable {
    public var `provider`: String
    public var `providerName`: String
    public var `model`: String
    public var `modelName`: String
    public var `voice`: String
    public var `voiceName`: String?
    public var `language`: String?
    public var `gender`: String?
    public var `preview`: String?
    public var `status`: String
    public init(`provider`: String, `providerName`: String, `model`: String, `modelName`: String, `voice`: String, `voiceName`: String?, `language`: String? = nil, `gender`: String? = nil, `preview`: String? = nil, `status`: String) {
        self.`provider` = `provider`
        self.`providerName` = `providerName`
        self.`model` = `model`
        self.`modelName` = `modelName`
        self.`voice` = `voice`
        self.`voiceName` = `voiceName`
        self.`language` = `language`
        self.`gender` = `gender`
        self.`preview` = `preview`
        self.`status` = `status`
    }
}

nonisolated public struct VoiceDefaults: Sendable, Equatable, Codable {
    public var `model`: String
    public var `voice`: String
    public init(`model`: String, `voice`: String) {
        self.`model` = `model`
        self.`voice` = `voice`
    }
}

nonisolated public struct VoiceProvider: Sendable, Equatable, Codable {
    public var `id`: String
    public var `name`: String
    public var `available`: Bool
    public var `models`: [String]
    public var `modelNames`: [String:String]?
    public var `default`: VoiceDefaults
    public var `defaultDetails`: VoiceDetails?
    public init(`id`: String, `name`: String, `available`: Bool, `models`: [String], `modelNames`: [String:String]? = nil, `default`: VoiceDefaults, `defaultDetails`: VoiceDetails? = nil) {
        self.`id` = `id`
        self.`name` = `name`
        self.`available` = `available`
        self.`models` = `models`
        self.`modelNames` = `modelNames`
        self.`default` = `default`
        self.`defaultDetails` = `defaultDetails`
    }
}

nonisolated public struct VoiceViewDetails: Sendable, Equatable, Codable {
    public var `saved`: VoiceDetails
    public var `effective`: VoiceDetails
    public init(`saved`: VoiceDetails, `effective`: VoiceDetails) {
        self.`saved` = `saved`
        self.`effective` = `effective`
    }
}

nonisolated public struct VoiceView: Sendable, Equatable, Codable {
    public var `effective`: VoiceSelection
    public var `saved`: SavedVoiceSelection
    public var `details`: VoiceViewDetails?
    public var `providers`: [VoiceProvider]
    public init(`effective`: VoiceSelection, `saved`: SavedVoiceSelection, `details`: VoiceViewDetails? = nil, `providers`: [VoiceProvider]) {
        self.`effective` = `effective`
        self.`saved` = `saved`
        self.`details` = `details`
        self.`providers` = `providers`
    }
}

nonisolated public struct CatalogVoice: Sendable, Equatable, Codable {
    public var `id`: String
    public var `name`: String
    public var `language`: String?
    public var `gender`: String?
    public var `description`: String?
    public var `preview`: String?
    public init(`id`: String, `name`: String, `language`: String? = nil, `gender`: String? = nil, `description`: String? = nil, `preview`: String? = nil) {
        self.`id` = `id`
        self.`name` = `name`
        self.`language` = `language`
        self.`gender` = `gender`
        self.`description` = `description`
        self.`preview` = `preview`
    }
}

nonisolated public struct VoiceCatalog: Sendable, Equatable, Codable {
    public var `provider`: String
    public var `voices`: [CatalogVoice]
    public var `next`: String?
    public init(`provider`: String, `voices`: [CatalogVoice], `next`: String? = nil) {
        self.`provider` = `provider`
        self.`voices` = `voices`
        self.`next` = `next`
    }
}

nonisolated public struct VoiceCatalogQuery: Sendable, Equatable, Codable {
    public var `provider`: String
    public var `q`: String?
    public var `language`: String?
    public var `gender`: String?
    public var `cursor`: String?
    public var `limit`: Int?
    public init(`provider`: String, `q`: String? = nil, `language`: String? = nil, `gender`: String? = nil, `cursor`: String? = nil, `limit`: Int? = nil) {
        self.`provider` = `provider`
        self.`q` = `q`
        self.`language` = `language`
        self.`gender` = `gender`
        self.`cursor` = `cursor`
        self.`limit` = `limit`
    }
}

nonisolated public struct HistoryQuery: Sendable, Equatable, Codable {
    public var `before`: Int64?
    public var `after`: Int64?
    public var `limit`: Int?
    public init(`before`: Int64? = nil, `after`: Int64? = nil, `limit`: Int? = nil) {
        self.`before` = `before`
        self.`after` = `after`
        self.`limit` = `limit`
    }
}

nonisolated public struct EventsQuery: Sendable, Equatable, Codable {
    public var `after`: Int64
    public init(`after`: Int64) {
        self.`after` = `after`
    }
}
public typealias FileTicketRenewResponse = FileInitResponse

nonisolated public enum JSONValue: Sendable, Equatable, Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

nonisolated public enum ThreadEntity: Sendable, Equatable, Codable {
    case message(Message), question(Question), unknown(JSONValue)
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "message": self = .message(try Message(from: decoder))
        case "question": self = .question(try Question(from: decoder))
        default: self = .unknown(try JSONValue(from: decoder))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .message(let v): try v.encode(to: encoder)
        case .question(let v): try v.encode(to: encoder)
        case .unknown(let v): try v.encode(to: encoder)
        }
    }
}

nonisolated public enum SigningText {
    public static func canonical(protocol version: Int, method: String, target: String, ts: Int64,
                                 nonce: String, bodyHash: String, deviceId: String) -> String {
        ["HEYDAN-SIG-V1", String(version), method, target, String(ts), nonce, bodyHash, deviceId].joined(separator: "\n")
    }
    public static func bodyHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func pairProof(code: String, publicKey: String) -> String {
        "HEYDAN-PAIR-V1\n\(code)\n\(publicKey)"
    }
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

nonisolated public struct Authorization: Sendable {
    public let header: String
    public init(protocol version: Int, deviceId: String, ts: Int64, nonce: Data, bodyHash: String, signature: Data) throws {
        guard version > 0, ts >= 0, nonce.count == 16, !deviceId.isEmpty,
              deviceId.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != "," && $0 != "=" }),
              bodyHash.count == 64, bodyHash.allSatisfy({ "0123456789abcdef".contains($0) }),
              (try? P256.Signing.ECDSASignature(derRepresentation: signature)) != nil else {
            throw ContractError.invalidAuthorization
        }
        header = "HeyDan-Sig v=1,p=\(version),d=\(deviceId),t=\(ts),n=\(SigningText.base64url(nonce)),bh=\(bodyHash),s=\(SigningText.base64url(signature))"
    }
}

nonisolated public enum ContractError: Error { case invalidAuthorization, invalidTarget, invalidUTF8, eventTooLarge, invalidEvent }

nonisolated public enum RequestTarget {
    public static func build(path: [String], query: [(String, String)] = []) throws -> String {
        guard path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(";") && !$0.contains("/") && !$0.contains("\\") }),
              query.allSatisfy({ !$0.0.isEmpty && !$0.0.contains(";") && !$0.1.contains(";") }) else {
            throw ContractError.invalidTarget
        }
        let route = (["app"] + path).map(encode).joined(separator: "/")
        let suffix = query.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        return "/" + route + (suffix.isEmpty ? "" : "?" + suffix)
    }
    private static func encode(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

nonisolated public struct AppEvent: Sendable, Equatable {
    public let kind: Kind
    public let id: Int64?
    public let data: Data
    public init(kind: Kind, id: Int64? = nil, data: Data) {
        self.kind = kind; self.id = id; self.data = data
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type, from: data) }
    public func cursor(after current: Int64) throws -> Int64 {
        switch kind {
        case .status, .badge: return current
        case .synchronized: return max(current, try decode(Synchronized.self).seq)
        default: return max(current, id ?? current)
        }
    }
}

nonisolated public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventKind = "message"
    private var eventID: Int64?
    private var skipLF = false
    private var atStart = true
    private var eventBytes = 0
    public let maximumEventBytes: Int
    public init(maximumEventBytes: Int = 4 * 1024 * 1024) { self.maximumEventBytes = maximumEventBytes }
    public mutating func feed(_ chunk: Data) throws -> [AppEvent] {
        var events: [AppEvent] = []
        for byte in chunk {
            if skipLF { skipLF = false; if byte == 10 { continue } }
            eventBytes += 1
            guard eventBytes <= maximumEventBytes else { throw ContractError.eventTooLarge }
            if byte == 10 || byte == 13 {
                try finishLine(into: &events)
                skipLF = byte == 13
            } else { line.append(byte) }
        }
        return events
    }
    private mutating func finishLine(into events: inout [AppEvent]) throws {
        if atStart {
            atStart = false
            if line.starts(with: [0xef, 0xbb, 0xbf]) { line.removeFirst(3) }
        }
        guard let text = String(bytes: line, encoding: .utf8) else { throw ContractError.invalidUTF8 }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            if !dataLines.isEmpty {
                events.append(AppEvent(kind: Kind(eventKind), id: eventID, data: Data(dataLines.joined(separator: "\n").utf8)))
            }
            dataLines.removeAll(keepingCapacity: true); eventKind = "message"; eventID = nil; eventBytes = 0
            return
        }
        if text.hasPrefix(":") { return }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch name {
        case "event": eventKind = value.isEmpty ? "message" : value
        case "data": dataLines.append(value)
        case "id":
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let id = Int64(value) else { throw ContractError.invalidEvent }
            eventID = id
        default: break
        }
    }
}
