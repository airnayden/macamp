// PlayEventSourceSurfaceTests — the surface a play is attributed to.
//
// `PlaybackSource` is frozen and persisted, so the surface is a flat projection
// of it rather than a second enum. The coordinator owns the ACTIVE source (the
// shell only mirrors it), which is what lets an emitted event name the surface
// the outgoing play came from even after the queue has already moved on.
import AudioEngine
import Foundation
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct PlayEventSourceSurfaceTests {
    @Test("the projection is total and stable across every PlaybackSource case")
    func projectionIsTotal() {
        let expected: [(source: PlaybackSource, surface: String)] = [
            (.librarySection("allTracks"), "library"),
            (.librarySection("lyrics"), "lyrics"),
            (.librarySection("albums"), "albums"),
            (.folder(path: "/Music"), "folder"),
            (.playlist(id: 3), "playlist"),
            (.favourites, "favourites"),
            (.karaokeReady, "karaoke"),
            (.search, "search"),
            (.albumDetail(id: 4), "album"),
            (.artistDetail(id: 5), "artist"),
            (.stats, "stats"),
        ]

        for expectation in expected {
            #expect(PlayEventSourceSurface.surface(for: expectation.source) == expectation.surface)
        }
        #expect(PlayEventSourceSurface.surface(for: nil) == "unknown")
    }

    @Test("(i) a sourced setQueue stamps that surface on every later signal")
    func sourcedQueueStampsSubsequentSignals() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue(
            [.fixture("a"), .fixture("b")],
            startingAt: 0,
            source: .playlist(id: 7)
        )
        harness.coordinator.seek(to: 5)

        harness.coordinator.next()

        #expect(harness.events.surfaces == ["playlist"])
    }

    @Test("(r) replacing a sourced queue stamps the OLD surface on the interrupted play")
    func replacementCarriesOutgoingSurface() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a")], startingAt: 0, source: .playlist(id: 7))
        harness.coordinator.seek(to: 5)

        harness.coordinator.setQueue([.fixture("b"), .fixture("c")], startingAt: 0, source: .favourites)
        harness.coordinator.seek(to: 5)
        harness.coordinator.next()

        #expect(harness.events.surfaces == ["playlist", "favourites"])
    }

    @Test("(s) removeAll clears the source, so the next unsourced play stamps unknown")
    func clearQueueClearsSource() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a")], startingAt: 0, source: .stats)
        harness.coordinator.seek(to: 5)
        harness.coordinator.removeAll()

        harness.coordinator.setQueue([.fixture("b"), .fixture("c")], startingAt: 0)
        harness.coordinator.seek(to: 5)
        harness.coordinator.next()

        #expect(harness.events.surfaces == ["stats", "unknown"])
    }

    @Test("(s) removeAll republishes a nil source to the shell mirror")
    func clearQueueRepublishesNilSource() throws {
        let harness = PlayEventHarness()
        let mirror = SourceMirror()
        harness.coordinator.playbackSourceDidChange = { mirror.record($0) }
        harness.coordinator.setQueue([.fixture("a")], startingAt: 0, source: .stats)

        harness.coordinator.removeAll()

        #expect(mirror.sources.count == 2)
        let republished = try #require(mirror.sources.last)
        #expect(republished == nil)
    }

    @Test("(t) a restore with no persisted source stamps unknown")
    func restoredNilSourceStampsUnknown() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a")], startingAt: 0, source: .search)
        let track = TrackRef.fixture("restored")

        harness.coordinator.restore(from: PlayEventHarness.snapshot(of: track, position: 3))
        harness.coordinator.setRestoredSource(nil)
        harness.coordinator.play()
        harness.coordinator.stop()

        #expect(harness.events.surfaces == ["unknown"])
    }

    @Test("(t) a playlist restore then resume then stop carries the playlist surface")
    func restoredPlaylistSourceSurvivesResume() {
        let harness = PlayEventHarness()
        let track = TrackRef.fixture("restored")

        harness.coordinator.restore(from: PlayEventHarness.snapshot(of: track, position: 3))
        harness.coordinator.setRestoredSource(.playlist(id: 12))
        harness.coordinator.play()
        harness.coordinator.stop()

        #expect(harness.events.surfaces == ["playlist"])
    }

    @Test("a manual play stamps queue while leaving the context source intact")
    func manualPlayStampsQueueSurface() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("context")], startingAt: 0, source: .favourites)
        harness.coordinator.enqueueManual(.fixture("manual"))

        harness.coordinator.playManual(at: 0)
        harness.coordinator.seek(to: 5)
        harness.coordinator.stop()

        #expect(harness.events.surfaces == ["favourites", "queue"])
    }

    @Test("stop() preserves the active source for the play that follows it")
    func stopPreservesSource() {
        let harness = PlayEventHarness()
        harness.coordinator.setQueue([.fixture("a"), .fixture("b")], startingAt: 0, source: .karaokeReady)
        harness.coordinator.stop()

        harness.coordinator.play()
        harness.coordinator.seek(to: 5)
        harness.coordinator.next()

        #expect(harness.events.surfaces == ["karaoke", "karaoke"])
    }
}

@MainActor
final class SourceMirror {
    private(set) var sources: [PlaybackSource?] = []

    func record(_ source: PlaybackSource?) {
        sources.append(source)
    }
}
