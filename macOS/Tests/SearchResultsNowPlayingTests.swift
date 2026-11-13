import Foundation
@testable import MacAMP
import SwiftUI
import Testing

/// The search-results table marks the playing row with a speaker glyph and an accent
/// title. Both read one predicate, so the predicate is pinned here rather than being
/// re-derived per call site — including the two idle cases, where marking any row
/// would be a lie about what the coordinator is doing.
@Suite("SearchResultsNowPlayingTests")
struct SearchResultsNowPlayingTests {
    @Test("the row whose id matches the current track is playing")
    func matchingIdsArePlaying() {
        #expect(SearchResultsView.isPlaying(rowTrackId: 5, currentTrackId: 5))
    }

    @Test("a row with a different id is not playing")
    func differingIdsAreNotPlaying() {
        #expect(SearchResultsView.isPlaying(rowTrackId: 5, currentTrackId: 6) == false)
    }

    @Test("a row with no persisted id is never playing")
    func unpersistedRowIsNotPlaying() {
        #expect(SearchResultsView.isPlaying(rowTrackId: nil, currentTrackId: 5) == false)
    }

    @Test("an idle player leaves every row unmarked")
    func idlePlayerMarksNothing() {
        #expect(SearchResultsView.isPlaying(rowTrackId: 5, currentTrackId: nil) == false)
    }
}

/// The wallpaper (`MacAMPBackdrop`) only reaches the screen when the scroll view
/// stops painting its own opaque background. That is a modifier pair with no runtime
/// value to assert, so it is pinned against the shipped source.
@Suite("SearchResultsBackdropTests")
struct SearchResultsBackdropTests {
    private static func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("macOS/Sources/SearchResultsView.swift"),
            encoding: .utf8
        )
    }

    @Test("the results table hides its own scroll background and washes the canvas")
    func tableLetsTheBackdropThrough() throws {
        let text = try Self.source()

        #expect(text.contains(".scrollContentBackground(.hidden)"))
        #expect(text.contains("tokens.colors.canvas.resolve(scheme).opacity(0.25)"))
    }
}
