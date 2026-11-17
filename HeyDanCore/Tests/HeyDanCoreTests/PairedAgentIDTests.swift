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
}
