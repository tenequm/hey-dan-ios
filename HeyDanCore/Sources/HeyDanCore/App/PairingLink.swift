import Foundation

/// One host as one string, however a pair link, a saved pairing or a push's `h` spells it: scheme and host lowercased,
/// the default port and any path, query or trailing slash dropped.
public enum PairedHost {
    public static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let scheme = parts.scheme?.lowercased()
        parts.scheme = scheme
        parts.percentEncodedHost = parts.percentEncodedHost?.lowercased()
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.user = nil; parts.password = nil
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    public static func key(_ text: String) -> String? { URL(string: text).map(key) }
}

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
