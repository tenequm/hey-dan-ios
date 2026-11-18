import Foundation
import HeyDanCore
import Testing

struct PairedAgentIDTests {
    @Test func stableAndScoped() {
        let host = URL(string: "https://example.com")!
        let id = PairedAgentID.make(host: host, agentId: "agent")
        #expect(id == PairedAgentID.make(host: host, agentId: "agent"))
        #expect(id != PairedAgentID.make(host: host, agentId: "other"))
        #expect(id != PairedAgentID.make(host: URL(string: "https://other.example.com")!, agentId: "agent"))
        #expect(id.uuid.6 >> 4 == 8)
        #expect(id.uuid.8 >> 6 == 2)
    }

    // A saved shortcut keeps this id across app updates: a change to the hash input must fail here.
    @Test func goldenVector() {
        let expected = UUID(uuidString: "6D67E7B7-8A06-89BC-B02D-8898606D9F61")
        #expect(PairedAgentID.make(host: URL(string: "https://app.example.com")!, agentId: "ag_taylor") == expected)
        #expect(PairedAgentID.make(host: URL(string: "HTTPS://App.Example.com:443/")!, agentId: "ag_taylor") == expected)
    }

    @Test func hostKeys() {
        #expect(PairedHost.key("https://app.example.com/") == "https://app.example.com")
        #expect(PairedHost.key("https://APP.example.com:443") == "https://app.example.com")
        #expect(PairedHost.key("http://127.0.0.1:4101/") == "http://127.0.0.1:4101")
        #expect(PairedHost.key("https://app.example.com:8443") == "https://app.example.com:8443")
        #expect(PairedHost.key("https://app.example.com") != PairedHost.key("http://app.example.com"))
    }
}
