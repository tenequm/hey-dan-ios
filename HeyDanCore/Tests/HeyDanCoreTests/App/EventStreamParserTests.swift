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

@Test func malformedFramesDoNotLoseTheirNeighborsOrDuplicateReplay() throws {
    let fixture = try coreFixtures()["messages"] as! [String: Any]
    let message = try fixtureDecode([Message].self, fixture["editSequence"]!).last!
    let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    let valid = Data("id: \(message.seq)\r\ndata: \(json)\r\n\r\n".utf8)
    let limit = valid.count
    let end = Data("\r\ndata: partial\r\n\r\n".utf8)
    for invalid in [Data("id: NaN".utf8), Data([0xff]), Data(repeating: 65, count: limit + 1)] {
        let stream = valid + invalid + end + valid
        var parser = SSEParser(maximumEventBytes: limit)
        var reducer = ThreadReducer()
        var events: [AppEvent] = []
        for byte in stream { events += try parser.feed(Data([byte])) }
        #expect(events.count == 2)
        #expect(try reducer.apply(events[0]) == [message.id])
        #expect(try reducer.apply(events[1]).isEmpty)
        #expect(reducer.cursor == message.seq)
        #expect(reducer.entities.count == 1)
        var whole = SSEParser(maximumEventBytes: limit)
        #expect(try whole.feed(stream) == events)
    }
}
