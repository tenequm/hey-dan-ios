import Foundation
import LiveKitWebRTC
import ObjectiveC.runtime
import Synchronization

enum PairedRelayICE {
    private struct Call {
        var report: (@Sendable (String) -> Void)?
    }

    private static let call = Mutex<Call?>(nil)

    static func begin(report: @escaping @Sendable (String) -> Void) {
        _ = install
        call.withLock { $0 = Call(report: report) }
    }

    static func end() {
        let pending = call.withLock { active in
            defer { active = nil }
            return active?.report
        }
        pending?("none")
    }

    // LiveKit 2.19 assigns the policy directly after the server list on join and reconnect.
    private static let install: Void = {
        let type = LKRTCConfiguration.self
        guard let setter = class_getInstanceMethod(type, #selector(setter: LKRTCConfiguration.iceTransportPolicy)),
              let hook = class_getInstanceMethod(type, #selector(LKRTCConfiguration.heyDanSetIceTransportPolicy(_:))) else {
            return assertionFailure("WebRTC ICE transport policy setter is unavailable")
        }
        method_exchangeImplementations(setter, hook)
    }()

    fileprivate static func apply(to configuration: LKRTCConfiguration) {
        call.withLock { active in
            guard active != nil, !configuration.iceServers.isEmpty else { return }
            let servers = configuration.iceServers
            let urls = servers.map { $0.urlStrings.map(TurnURL.init) }
            let tlsHosts = urls.map { $0.compactMap { $0?.tlsHost }.first }
            var transports = Set<String>()
            let updated = servers.enumerated().map { index, server in
                let host = tlsHosts[index] ?? servers.indices.lazy.compactMap { other in
                    servers[other].username == server.username && servers[other].credential == server.credential
                        ? tlsHosts[other] : nil
                }.first
                let rewritten = zip(server.urlStrings, urls[index]).map { original, url in
                    if let transport = url?.transport { transports.insert(transport) }
                    return url?.replacingUDPHost(with: host) ?? original
                }
                guard rewritten != server.urlStrings else { return server }
                return LKRTCIceServer(urlStrings: rewritten, username: server.username, credential: server.credential,
                                      tlsCertPolicy: server.tlsCertPolicy, hostname: server.hostname,
                                      tlsAlpnProtocols: server.tlsAlpnProtocols, tlsEllipticCurves: server.tlsEllipticCurves)
            }
            if zip(servers, updated).contains(where: { $0 !== $1 }) { configuration.iceServers = updated }
            active?.report?(transports.isEmpty ? "none" : transports.sorted().joined(separator: ","))
            active?.report = nil
        }
    }
}

private extension LKRTCConfiguration {
    @objc dynamic func heyDanSetIceTransportPolicy(_ policy: LKRTCIceTransportPolicy) {
        heyDanSetIceTransportPolicy(policy)
        if policy == .relay { PairedRelayICE.apply(to: self) }
    }
}

private struct TurnURL {
    let scheme: Substring
    let host: String
    let suffix: Substring
    let transport: String

    init?(_ raw: String) {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        scheme = raw[..<colon]
        let endpoint = raw[raw.index(after: colon)...]
        let kind = scheme.lowercased()
        guard kind == "turn" || kind == "turns",
              let parts = URLComponents(string: "//" + endpoint, encodingInvalidCharacters: false),
              let host = parts.encodedHost, !host.isEmpty, endpoint.hasPrefix(host),
              parts.user == nil, parts.password == nil,
              parts.path.isEmpty, parts.fragment == nil else { return nil }
        self.host = host
        suffix = endpoint.dropFirst(host.count)
        let parameter = parts.queryItems?.first { $0.name.lowercased() == "transport" }
        switch (kind, parameter?.value?.lowercased()) {
        case ("turns", _): transport = "tls"
        case ("turn", "tcp"): transport = "tcp"
        case ("turn", "udp"): transport = "udp"
        case ("turn", nil) where parameter == nil: transport = "udp"
        default: return nil
        }
    }

    var tlsHost: String? { transport == "tls" ? host : nil }

    func replacingUDPHost(with host: String?) -> String? {
        guard transport == "udp", let host, host != self.host else { return nil }
        return scheme + ":" + host + suffix
    }
}
