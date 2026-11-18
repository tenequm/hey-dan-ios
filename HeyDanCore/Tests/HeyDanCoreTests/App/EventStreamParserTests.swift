import Foundation
import Testing
@testable import HeyDanCore

func coreFixtures() throws -> [String: Any] {
    let url = Bundle.module.url(forResource: "app-contract.fixtures", withExtension: "json")!
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}
func fixtureDecode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
}

@Test func foundationLinesDropsEventSeparators() async throws {
    let raw = (try coreFixtures()["stream"] as! [String: Any])["raw"] as! String
    let stream = AsyncStream<UInt8> { continuation in
        for byte in raw.utf8 { continuation.yield(byte) }
        continuation.finish()
    }
    var empty = 0
    for try await line in stream.lines { if line.isEmpty { empty += 1 } }
    #expect(empty == 0)
    #expect(raw.contains("\n\n"))
}

@Test func everyStreamSplit() throws {
    let fixture = try coreFixtures()["stream"] as! [String: Any]
    let raw = Data((fixture["raw"] as! String).utf8)
    let expected = (fixture["expect"] as! [String: Any])["kindsInOrder"] as! [String]
    var baseline = SSEParser()
    let whole = try baseline.feed(raw)
    for split in 0...raw.count {
        var parser = SSEParser()
        let events = try parser.feed(raw.prefix(split)) + parser.feed(raw.suffix(raw.count - split))
        #expect(events == whole)
        #expect(events.map { $0.kind.rawValue } == expected)
    }
}
