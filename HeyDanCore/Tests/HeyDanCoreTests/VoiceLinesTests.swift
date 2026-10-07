import Foundation
import HeyDanCore
import Testing

struct VoiceLinesTests {
    private func line(_ token: String) throws -> VoiceLine {
        try #require(VoiceLine(callLink: "https://lines.example/voice?t=\(token)"))
    }

    @Test func addingPicksTheNewLineAndKeepsOneEntryPerLink() throws {
        var lines = VoiceLines()
        #expect(lines.selected == nil)
        let dan = lines.add(try line("fake-dan"), agent: "Dan")
        let emma = lines.add(try line("fake-emma"))
        #expect(lines.selected?.id == emma)
        #expect(lines.add(try line("fake-dan")) == dan)
        #expect(lines.entries.count == 2)
        #expect(lines.selected?.id == dan)
        #expect(lines.entry(dan)?.agent == "Dan")
    }

    @Test func removingThePickedLineFallsBackToTheFirst() throws {
        var lines = VoiceLines()
        let dan = lines.add(try line("fake-dan"))
        let emma = lines.add(try line("fake-emma"))
        let stan = lines.add(try line("fake-stan"))
        lines.select(emma)
        lines.remove(stan)
        #expect(lines.selected?.id == emma)
        lines.remove(emma)
        #expect(lines.selected?.id == dan)
        lines.remove(dan)
        #expect(lines.selected == nil)
        lines.select(dan)
        #expect(lines.selected == nil)
    }

    @Test func namingIgnoresBlanksAndRepeats() throws {
        var lines = VoiceLines()
        let id = lines.add(try line("fake-dan"))
        let blank = lines.name(id, agent: "  ")
        let named = lines.name(id, agent: " Concierge\n")
        let again = lines.name(id, agent: "Concierge")
        let unknown = lines.name(UUID(), agent: "Stan")
        #expect(!blank && named && !again && !unknown)
        #expect(lines.entry(id)?.agent == "Concierge")
    }

    @Test func roundTripsThroughJSON() throws {
        var lines = VoiceLines()
        lines.add(try line("fake-dan"), agent: "Dan")
        let emma = lines.add(try line("fake-emma"))
        lines.add(try line("fake-stan"), agent: "Stan")
        lines.select(emma)
        let decoded = try JSONDecoder().decode(VoiceLines.self, from: try JSONEncoder().encode(lines))
        #expect(decoded == lines)
        #expect(decoded.selected?.id == emma)
        #expect(decoded.selected?.agent == nil)
    }

    @Test func unreadableLinesStayAsideAndGoBackOnEverySave() throws {
        var lines = VoiceLines()
        lines.add(try line("fake-dan"), agent: "Dan")
        let emma = lines.add(try line("fake-emma"))
        var stored = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(lines)) as? [String: Any])
        var entries = try #require(stored["entries"] as? [[String: Any]])
        let damaged: [String: Any] = ["id": UUID().uuidString, "link": "not a link"]
        let newer: [String: Any] = [
            "id": UUID().uuidString, "lines": ["https://lines.example/voice?t=fake-stan"], "since": 2.5, "pinned": true,
            "big": 9_007_199_254_740_993, "note": NSNull(),
        ]
        entries.insert(damaged, at: 1)
        entries.append(newer)
        stored["entries"] = entries
        var decoded = try JSONDecoder().decode(VoiceLines.self, from: try JSONSerialization.data(withJSONObject: stored))
        #expect(decoded.entries == lines.entries && decoded.unreadableCount == 2)
        #expect(decoded.selected?.id == emma)

        let stan = decoded.add(try line("fake-stan"))
        decoded.name(stan, agent: "Stan")
        decoded.remove(emma)
        let saved = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as? [String: Any]
        )
        let savedEntries = try #require(saved["entries"] as? [NSDictionary])
        #expect(savedEntries.count == 4)
        #expect(savedEntries.contains(damaged as NSDictionary) && savedEntries.contains(newer as NSDictionary))
        let reread = try JSONDecoder().decode(VoiceLines.self, from: try JSONEncoder().encode(decoded))
        #expect(reread == decoded && reread.entries.count == 2 && reread.unreadableCount == 2)
        #expect(reread.selected?.id == stan)

        #expect(throws: (any Error).self) { try JSONDecoder().decode(VoiceLines.self, from: Data("[1,2]".utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VoiceLines.self, from: Data(#"{"lines":[]}"#.utf8)) }
    }

    @Test func migratesTheSingleLegacyLink() {
        let lines = VoiceLines(legacyLink: "https://lines.example/voice?t=fake-old")
        #expect(lines.entries.count == 1)
        #expect(lines.selected?.line.token == "fake-old")
        #expect(lines.selected?.agent == nil)
        #expect(VoiceLines(legacyLink: "not a link").entries.isEmpty)
    }

    @Test func infoAsksTheHostWithoutStartingACall() throws {
        let request = try line("fake-dan").infoRequest
        #expect(request.url?.absoluteString == "https://lines.example/voice/info?t=fake-dan")
        #expect(request.httpMethod == "GET")
    }

    @Test func decodesTheLineInfo() throws {
        let info = try LineInfo(status: 200, body: Data(#"{"agent":"Emma","caller":"Misha","wakePhrase":null}"#.utf8))
        #expect(info.agent == "Emma")
        #expect(throws: CallFailure.refused(status: 403, body: "Unknown call link")) {
            try LineInfo(status: 403, body: Data("Unknown call link".utf8))
        }
        #expect(throws: CallFailure.malformedGrant) { try LineInfo(status: 200, body: Data("<html>".utf8)) }
    }
}
