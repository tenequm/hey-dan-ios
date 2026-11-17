import Foundation
import Testing
@testable import HeyDanCore

@Test func pairingLinks() throws {
    let f = try coreFixtures()["pairLink"] as! [String: Any]
    let link = f["link"] as! String, local = f["localLink"] as! String
    let parsed = PairingLink(link)
    checkCore(parsed?.baseURL.absoluteString == f["host"] as? String)
    checkCore(parsed?.code == f["code"] as? String)
    checkCore(PairingLink(local) == nil)
    checkCore(PairingLink(local, allowsLocalNetworking: true)?.baseURL.absoluteString == f["localHost"] as? String)
    for invalid in [" " + link, link + " junk", "https://example.com/app/pair?code=x#y", "https://example.com/app/pair#", "https://example.com/pair#x", "http://example.com/app/pair#x", "https://user@example.com/app/pair#x", "https://example.com/app/pair#%0A", "http://127.example.com/app/pair#x"] {
        checkCore(PairingLink(invalid, allowsLocalNetworking: true) == nil)
    }
    for host in ["localhost", "127.0.0.1", "127.1.2.3", "[::1]"] {
        checkCore(PairingLink("http://\(host):4101/app/pair#x", allowsLocalNetworking: true) != nil)
    }
}
