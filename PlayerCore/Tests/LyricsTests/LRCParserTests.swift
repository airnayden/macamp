import Foundation
@testable import Lyrics
import Testing

@Suite("LRCParserTests")
struct LRCParserTests {
    @Test("parses the committed sample .lrc: metadata, offset, lines, word timings")
    func parsesSampleFixture() throws {
        let url = lyricsFixtureURL("sample.lrc")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lyrics = LRCParser.parse(text)

        #expect(lyrics.source == .lrcFile)
        #expect(lyrics.isSynced)
        #expect(lyrics.metadata["ar"] == "Test Artist")
        #expect(lyrics.metadata["ti"] == "Test Song")
        #expect(lyrics.metadata["al"] == "Test Album")
        #expect(lyrics.metadata["by"] == "MacAMP")
        #expect(approxEqual(lyrics.offset, 0.5))

        #expect(lyrics.lines.count == 4)
        #expect(lyrics.lines[0].text == "First line")
        #expect(approxEqual(lyrics.lines[0].time ?? -1, 9.5))
        #expect(approxEqual(lyrics.lines[1].time ?? -1, 12.0))
        #expect(approxEqual(lyrics.lines[2].time ?? -1, 14.5))
        #expect(lyrics.lines[3].text == "Last line")
        #expect(approxEqual(lyrics.lines[3].time ?? -1, 19.5))
    }

    @Test("enhanced .lrc word timings parse with the offset folded in")
    func parsesWordTimings() throws {
        let url = lyricsFixtureURL("sample.lrc")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lyrics = LRCParser.parse(text)

        #expect(lyrics.lines[2].text == "Third line words")
        let words = try #require(lyrics.lines[2].words)
        #expect(words.count == 3)
        #expect(words[0].text == "Third ")
        #expect(words[1].text == "line ")
        #expect(words[2].text == "words")
        #expect(approxEqual(words[0].time, 14.5))
        #expect(approxEqual(words[1].time, 15.7))
        #expect(approxEqual(words[2].time, 16.9))
    }

    @Test("a line with multiple leading timestamps expands to one line each")
    func parsesMultipleTimestamps() {
        let lyrics = LRCParser.parse("[00:01.00][00:05.00]repeat")
        #expect(lyrics.lines.count == 2)
        #expect(approxEqual(lyrics.lines[0].time ?? -1, 1.0))
        #expect(approxEqual(lyrics.lines[1].time ?? -1, 5.0))
        #expect(lyrics.lines[0].text == "repeat")
        #expect(lyrics.lines[1].text == "repeat")
    }

    @Test("plain text with no timestamps is unsynced")
    func parsesPlainTextAsUnsynced() {
        let lyrics = LRCParser.parse("just text\nmore text")
        #expect(!lyrics.isSynced)
        #expect(lyrics.lines.count == 2)
        #expect(lyrics.lines[0].time == nil)
        #expect(lyrics.lines[0].text == "just text")
    }

    @Test("containsTimestamps detects synced vs plain blobs")
    func detectsTimestamps() {
        #expect(LRCParser.containsTimestamps("[00:01.00]x"))
        #expect(LRCParser.containsTimestamps("intro\n[01:02.30]chorus"))
        #expect(!LRCParser.containsTimestamps("plain words only"))
        #expect(!LRCParser.containsTimestamps("[ti:not a time]"))
    }
}
