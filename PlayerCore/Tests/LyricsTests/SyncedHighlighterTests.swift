import Foundation
@testable import Lyrics
import Testing

@Suite("SyncedHighlighterTests")
struct SyncedHighlighterTests {
    private let highlighter = SyncedHighlighter(lines: [
        LyricLine(time: 10, text: "a"),
        LyricLine(time: 30, text: "b"),
        LyricLine(time: 60, text: "c"),
        LyricLine(time: 73, text: "at seventy-three"),
        LyricLine(time: 90, text: "e"),
    ])

    @Test("activeLine(at: 73.5) lands on the line at 73 via binary search")
    func activeLineAt73Point5() {
        #expect(highlighter.activeLineIndex(at: 73.5) == 3)
        #expect(highlighter.activeLine(at: 73.5)?.text == "at seventy-three")
    }

    @Test("playhead before the first line has no active line")
    func beforeFirstLine() {
        #expect(highlighter.activeLineIndex(at: 5) == nil)
        #expect(highlighter.activeLine(at: 5) == nil)
    }

    @Test("exact-boundary and after-last lookups")
    func boundaries() {
        #expect(highlighter.activeLine(at: 60)?.text == "c")
        #expect(highlighter.activeLine(at: 10)?.text == "a")
        #expect(highlighter.activeLine(at: 1000)?.text == "e")
        #expect(highlighter.activeLineIndex(at: 1000) == 4)
    }

    @Test("unsynced lines are excluded; empty highlighter resolves to nil")
    func excludesUnsynced() {
        let plain = SyncedHighlighter(lines: [LyricLine(text: "x"), LyricLine(text: "y")])
        #expect(plain.isEmpty)
        #expect(plain.activeLineIndex(at: 42) == nil)
    }

    @Test("word-level binary search returns the active word index")
    func activeWord() {
        let line = LyricLine(
            time: 14.5,
            text: "Third line words",
            words: [
                TimedWord(time: 14.5, text: "Third "),
                TimedWord(time: 15.7, text: "line "),
                TimedWord(time: 16.9, text: "words"),
            ]
        )
        let wordHighlighter = SyncedHighlighter(lines: [line])
        #expect(wordHighlighter.activeWordIndex(at: 14.0, inLineAt: 0) == nil)
        #expect(wordHighlighter.activeWordIndex(at: 14.5, inLineAt: 0) == 0)
        #expect(wordHighlighter.activeWordIndex(at: 16.0, inLineAt: 0) == 1)
        #expect(wordHighlighter.activeWordIndex(at: 100, inLineAt: 0) == 2)

        let position = wordHighlighter.activePosition(at: 16.0)
        #expect(position?.lineIndex == 0)
        #expect(position?.wordIndex == 1)
    }
}
