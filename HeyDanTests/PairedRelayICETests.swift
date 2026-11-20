import LiveKitWebRTC
import Synchronization
import Testing
@testable import HeyDan

struct PairedRelayICETests {
    @Test func serverOfferAtTheWebRTCConfigurationBoundary() {
        let udp = "turn:192.0.2.5:03478?x=%2f&transport=udp&x=2"
        let ipv6 = "turn:[2001:db8::1]:3479"
        let tls = "turns:relay.example:443?transport=tcp"
        let tcp = "turn:192.0.2.5:80?transport=tcp"
        let stun = "stun:192.0.2.7:3478"
        let mixed = LKRTCIceServer(urlStrings: [udp, ipv6, tcp, stun, tls], username: "user", credential: "first",
                                   tlsCertPolicy: .secure, hostname: "sni.example",
                                   tlsAlpnProtocols: ["test"], tlsEllipticCurves: ["P-256"])
        let sameCredentials = LKRTCIceServer(urlStrings: [ipv6], username: "user", credential: "first")
        let separate = LKRTCIceServer(urlStrings: [udp], username: "user", credential: "second")
        let ipv6Edge = LKRTCIceServer(urlStrings: ["turns:[2001:db8::2]:443", udp], username: "other", credential: nil)
        let offer = [mixed, sameCredentials, separate, ipv6Edge]
        let configuration = LKRTCConfiguration()
        configuration.iceServers = offer
        configuration.iceTransportPolicy = .relay
        #expect(configuration.iceServers.first === mixed)

        let reports = Mutex<[String]>([])
        PairedRelayICE.begin { offered in reports.withLock { $0.append(offered) } }
        configuration.iceServers = []
        configuration.iceTransportPolicy = .relay
        configuration.iceServers = offer
        configuration.iceTransportPolicy = .all
        #expect(reports.withLock { $0.isEmpty })
        #expect(configuration.iceServers.first === mixed)
        configuration.iceTransportPolicy = .relay

        let result = configuration.iceServers
        #expect(result[0].urlStrings == ["turn:relay.example:03478?x=%2f&transport=udp&x=2",
                                         "turn:relay.example:3479", tcp, stun, tls])
        #expect(result[0].username == mixed.username && result[0].credential == mixed.credential)
        #expect(result[0].tlsCertPolicy == mixed.tlsCertPolicy && result[0].hostname == mixed.hostname)
        #expect(result[0].tlsAlpnProtocols == mixed.tlsAlpnProtocols && result[0].tlsEllipticCurves == mixed.tlsEllipticCurves)
        #expect(result[1].urlStrings == ["turn:relay.example:3479"])
        #expect(result[2] === separate)
        #expect(result[3].urlStrings == ["turns:[2001:db8::2]:443", "turn:[2001:db8::2]:03478?x=%2f&transport=udp&x=2"])

        configuration.iceServers = [sameCredentials]
        configuration.iceTransportPolicy = .relay
        #expect(configuration.iceServers.first === sameCredentials)
        #expect(reports.withLock { $0 } == ["tcp,tls,udp"])

        PairedRelayICE.end()
        configuration.iceServers = offer
        configuration.iceTransportPolicy = .relay
        #expect(configuration.iceServers.first === mixed)

        PairedRelayICE.begin { offered in reports.withLock { $0.append(offered) } }
        configuration.iceServers = []
        configuration.iceTransportPolicy = .relay
        PairedRelayICE.end()
        #expect(reports.withLock { $0 } == ["tcp,tls,udp", "none"])
    }
}
