import Foundation
import os

/// Tailscale on the phone is a VPN (a Network Extension): while it is connected a `utun` interface holds the
/// device's tailnet address, and when it is off that interface is gone. A tailnet-only line is then unreachable,
/// and its token request would only say so once it times out.
public enum Tailnet {
    public struct InterfaceAddress: Sendable, Equatable {
        public let interface: String
        public let address: String

        public init(interface: String, address: String) {
            self.interface = interface
            self.address = address
        }
    }

    /// Whether an interface address means Tailscale is up: 100.64.0.0/10 or fd7a:115c:a1e0::/48. 100.64.0.0/10 is also carrier-grade NAT, which a
    /// cellular interface (`pdp_ip*`) can hold without any tailnet.
    public static func isTailnetInterface(_ entry: InterfaceAddress) -> Bool {
        guard let address = bytes(entry.address), isTailnet(address) else { return false }
        return !(address.count == 4 && entry.interface.hasPrefix("pdp_ip"))
    }

    /// Whether the line's host can only be reached over the tailnet: it resolved, and to tailnet addresses alone
    /// (a DNS64 synthesis in 64:ff9b::/96 counts as the IPv4 address it embeds).
    public static func isTailnetOnly(_ hostAddresses: [String]) -> Bool {
        !hostAddresses.isEmpty && hostAddresses.allSatisfy { text in
            guard let address = bytes(text) else { return false }
            let nat64 = address.count == 16 && address.starts(with: nat64Prefix)
            return isTailnet(nat64 ? Array(address.suffix(4)) : address)
        }
    }

    /// Off only when sure: no interface holds a tailnet address and the host is tailnet-only. Anything less
    /// lets the call go ahead, so a misread never blocks a call that would have worked.
    public static func looksOff(hostAddresses: [String], interfaces: [InterfaceAddress]) -> Bool {
        !interfaces.contains(where: isTailnetInterface) && isTailnetOnly(hostAddresses)
    }

    /// What the precheck found, and on which branch: only `.off` stops a call.
    public enum Verdict: Sendable, Equatable {
        /// An interface holds a tailnet address.
        case on
        /// No tailnet interface, and the host resolves to tailnet addresses alone.
        case off
        /// Not sure, so the call goes ahead; `reason` names the branch for the log.
        case unknown(reason: String)

        public var logName: String {
            switch self {
            case .on: "on"
            case .off: "off"
            case let .unknown(reason): "unknown(\(reason))"
            }
        }
    }

    /// Reads this device's interfaces and, only when none holds a tailnet address, resolves `host`. A failed
    /// read, a failed lookup or one slower than `resolveTimeout` is `.unknown`.
    public static func check(host: String) async -> Verdict {
        guard let interfaces = interfaceAddresses() else { return .unknown(reason: "interfaces-unreadable") }
        return await check(interfaces: interfaces) { await resolve(host) }
    }

    static func check(interfaces: [InterfaceAddress], lookup: () async -> Lookup) async -> Verdict {
        guard !interfaces.contains(where: isTailnetInterface) else { return .on }
        switch await lookup() {
        case .timedOut: return .unknown(reason: "lookup-timeout")
        case .failed: return .unknown(reason: "lookup-failed")
        case let .addresses(hostAddresses):
            return looksOff(hostAddresses: hostAddresses, interfaces: interfaces) ? .off : .unknown(reason: "host-not-tailnet-only")
        }
    }

    private static let resolveTimeout: DispatchTimeInterval = .milliseconds(1500)
    private static let nat64Prefix: [UInt8] = [0x00, 0x64, 0xFF, 0x9B] + Array(repeating: 0, count: 8)

    private static func isTailnet(_ address: [UInt8]) -> Bool {
        switch address.count {
        case 4: address[0] == 100 && address[1] & 0xC0 == 64
        case 16: address.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
        default: false
        }
    }

    private static func bytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }

    private static func interfaceAddresses() -> [InterfaceAddress]? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { entry in
            guard let address = entry.pointee.ifa_addr, let text = numericHost(address) else { return nil }
            return InterfaceAddress(interface: String(cString: entry.pointee.ifa_name), address: text)
        }
    }

    enum Lookup: Sendable {
        case addresses([String])
        case failed
        case timedOut
    }

    /// getaddrinfo cannot be cancelled, so a slow lookup is left to finish on its own after the timeout answers.
    private static func resolve(_ host: String) async -> Lookup {
        await withCheckedContinuation { continuation in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Lookup) -> Void = { lookup in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: lookup) }
            }
            DispatchQueue.global().async { answer(addresses(of: host).map(Lookup.addresses) ?? .failed) }
            DispatchQueue.global().asyncAfter(deadline: .now() + resolveTimeout) { answer(.timedOut) }
        }
    }

    private static func addresses(of host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        return sequence(first: first, next: { $0.pointee.ai_next }).compactMap { $0.pointee.ai_addr.flatMap { numericHost($0) } }
    }

    /// Only IPv4 and IPv6; a scoped IPv6 address keeps its `%interface` suffix and so never parses as tailnet.
    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        return host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
