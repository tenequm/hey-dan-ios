import Foundation

public struct PairingLink: Sendable, Equatable {
    public let baseURL: URL
    public let code: String
    public init?(_ text: String, allowsLocalNetworking: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: text),
              parts.user == nil, parts.password == nil, parts.query == nil,
              parts.percentEncodedPath == "/app/pair",
              let host = parts.host, !host.isEmpty,
              let code = parts.fragment, !code.isEmpty,
              !code.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let loopback = host.lowercased() == "localhost" || host == "[::1]" || host == "::1" || {
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            return octets.count == 4 && octets[0] == "127" && octets.allSatisfy {
                !$0.isEmpty && $0.allSatisfy(\.isNumber) && (UInt8($0) != nil)
            }
        }()
        guard parts.scheme?.lowercased() == "https" ||
                (parts.scheme?.lowercased() == "http" && allowsLocalNetworking && loopback) else { return nil }
        parts.path = ""; parts.fragment = nil
        guard let url = parts.url else { return nil }
        baseURL = url
        self.code = code
    }
}
