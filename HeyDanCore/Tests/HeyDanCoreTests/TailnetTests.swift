@testable import HeyDanCore
import Testing

struct TailnetTests {
    @Test(arguments: ["100.64.0.0", "100.101.17.42", "100.127.255.255", "fd7a:115c:a1e0::1234:5678", "fd7a:115c:a1e0:ab12::1"])
    func containsTailscaleRanges(_ address: String) {
        #expect(Tailnet.isTailnetInterface(.init(interface: "utun4", address: address)))
    }

    @Test(arguments: ["100.63.255.255", "100.128.0.0", "10.0.0.1", "192.168.50.100", "fd7a:115c:a1e1::1", "fe80::1", "", "voice.example.com"])
    func leavesOutEverythingElse(_ address: String) {
        #expect(!Tailnet.isTailnetInterface(.init(interface: "utun4", address: address)))
    }

    @Test func aTailnetLineNeedsATailnetHostOnly() {
        #expect(Tailnet.isTailnetOnly(["100.101.17.42"]))
        #expect(Tailnet.isTailnetOnly(["64:ff9b::6465:112a"]))
        #expect(!Tailnet.isTailnetOnly([]))
        #expect(!Tailnet.isTailnetOnly(["100.101.17.42", "203.0.113.7"]))
        #expect(!Tailnet.isTailnetOnly(["64:ff9b::cb00:7107"]))
    }

    @Test func carrierNATOnCellularIsNotTailscale() {
        #expect(!Tailnet.isTailnetInterface(.init(interface: "pdp_ip0", address: "100.70.12.3")))
        #expect(Tailnet.isTailnetInterface(.init(interface: "utun4", address: "100.90.3.7")))
        #expect(Tailnet.isTailnetInterface(.init(interface: "utun4", address: "fd7a:115c:a1e0::1234:5678")))
        #expect(!Tailnet.isTailnetInterface(.init(interface: "utun0", address: "fe80::1%utun0")))
    }

    private let phoneOffline: [Tailnet.InterfaceAddress] = [
        .init(interface: "lo0", address: "127.0.0.1"),
        .init(interface: "en0", address: "192.168.50.42"),
        .init(interface: "pdp_ip0", address: "100.70.12.3"),
        .init(interface: "utun0", address: "fe80::1%utun0"),
    ]

    @Test func offOnlyWithoutATailnetInterfaceAndWithATailnetHost() {
        #expect(Tailnet.looksOff(hostAddresses: ["100.101.17.42"], interfaces: phoneOffline))
        let tailscaleUp = phoneOffline + [.init(interface: "utun5", address: "100.90.3.7")]
        #expect(!Tailnet.looksOff(hostAddresses: ["100.101.17.42"], interfaces: tailscaleUp))
        #expect(!Tailnet.looksOff(hostAddresses: ["203.0.113.7"], interfaces: phoneOffline))
        #expect(!Tailnet.looksOff(hostAddresses: [], interfaces: phoneOffline))
    }

    @Test func onlyATailnetOnlyHostWithoutATailnetInterfaceStopsTheCall() async {
        let tailnetHost: () async -> Tailnet.Lookup = { .addresses(["100.101.17.42"]) }
        #expect(await Tailnet.check(interfaces: phoneOffline, lookup: tailnetHost) == .off)
        #expect(await Tailnet.check(interfaces: phoneOffline + [.init(interface: "utun5", address: "100.90.3.7")], lookup: tailnetHost) == .on)
        #expect(await Tailnet.check(interfaces: phoneOffline) { .failed } == .unknown(reason: "lookup-failed"))
        #expect(await Tailnet.check(interfaces: phoneOffline) { .timedOut } == .unknown(reason: "lookup-timeout"))
        #expect(await Tailnet.check(interfaces: phoneOffline) { .addresses(["203.0.113.7"]) } == .unknown(reason: "host-not-tailnet-only"))
    }
}
