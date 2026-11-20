import Foundation
import Testing
@testable import HeyDanCore

@Test func pairingLinks() throws {
    let f = try coreFixtures()["pairLink"] as! [String: Any]
    let link = f["link"] as! String, local = f["localLink"] as! String
    #expect(PairingLink(" \n" + link + "\n ") == PairingLink(link))
    let parsed = PairingLink(link)
    #expect(parsed?.baseURL.absoluteString == f["host"] as? String)
    #expect(parsed?.code == f["code"] as? String)
    #expect(PairingLink("HTTPS://Example.COM:443/app/pair#x")?.baseURL.absoluteString == "https://example.com")
    #expect(PairingLink(local) == nil)
    #expect(PairingLink(local, allowsLocalNetworking: true)?.baseURL.absoluteString == f["localHost"] as? String)
    for invalid in [link + " junk", "https://example.com/app/pair?code=x#y", "https://example.com/app/pair#", "https://example.com/pair#x", "http://example.com/app/pair#x", "https://user@example.com/app/pair#x", "https://example.com/app/pair#%0A", "http://127.example.com/app/pair#x"] {
        #expect(PairingLink(invalid, allowsLocalNetworking: true) == nil)
    }
    for host in ["localhost", "127.0.0.1", "127.1.2.3", "[::1]"] {
        #expect(PairingLink("http://\(host):4101/app/pair#x", allowsLocalNetworking: true) != nil)
    }
}

@Test func betaLinksOpenOnlyHTTPSPairing() throws {
    let url = try #require(URL(string: "heydan-beta://example.com:8443/app/pair#a%2Fb"))
    #expect(PairingLink.betaDestination(url)?.absoluteString == "https://example.com:8443/app/pair#a%2Fb")
    for invalid in ["facetime://example.com/app/pair#x", "heydan-beta://example.com/app/call#x",
                    "heydan-beta://example.com/app/pair", "heydan-beta://user@example.com/app/pair#x",
                    "heydan-beta://example.com/app/pair?code=x", "heydan-beta://example.com/app/pair#%0A"] {
        #expect(PairingLink.betaDestination(try #require(URL(string: invalid))) == nil)
    }
}
