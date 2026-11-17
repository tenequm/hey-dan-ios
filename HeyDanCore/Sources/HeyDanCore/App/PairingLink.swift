import Foundation

/// H1 owns pairing-link validation, including Debug loopback policy.
public struct PairingLink: Sendable, Equatable {
    public let baseURL: URL
    public let code: String
    public init?(_ text: String, allowsLocalNetworking: Bool = false) { return nil }
}
