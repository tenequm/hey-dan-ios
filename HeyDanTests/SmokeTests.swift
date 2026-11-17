import Foundation
import Testing
import HeyDanCore
@testable import HeyDan

private final class FixtureBundle {}

@Test func contractFixtureIsBundled() throws {
    let url = try #require(Bundle(for: FixtureBundle.self).url(forResource: "app-contract.fixtures", withExtension: "json"))
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let data = try JSONSerialization.data(withJSONObject: object["hello"]!)
    let hello = try JSONDecoder().decode(HelloResponse.self, from: data)
    #expect(hello.protocol == 1)
}
