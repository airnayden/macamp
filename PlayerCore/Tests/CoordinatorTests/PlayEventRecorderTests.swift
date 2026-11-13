// PlayEventRecorderTests — what actually lands in the v15 `playEvent` table.
//
// Driven through the REAL coordinator wherever the behaviour depends on how a
// transition is raised (natural end, skip, zero-elapsed), and through direct
// signals where it depends only on the recorder's own arithmetic or on state a
// coordinator cannot stage (a DST boundary, a deleted track row).
import AudioEngine
import Foundation
import GRDB
import Persistence
@testable import Services
import Testing

/// Mutable stand-in for `ProfileService.activeProfile.id`, so a test can flip the
/// active profile between the recorder's capture point and its emit point.
@MainActor
private final class RecorderProfileBox {
    var id: Int64
    init(_ id: Int64) {
        self.id = id
    }
}

private let seededTrackId: Int64 = 1
private let probeDuration: Double = 100
private let probeEpoch: Double = 1_700_000_000
/// 2024-01-01 — New York is on EST (−5 h).
private let winterEpoch: Double = 1_704_100_000
/// 2024-07-03 — New York is on EDT (−4 h).
private let summerEpoch: Double = 1_720_000_000

@MainActor
@Suite("PlayEventRecorderTests", .serialized)
struct PlayEventRecorderTests {
    private struct Harness {
        let database: AppDatabase
        let coordinator: PlaybackCoordinator
        let recorder: PlayEventRecorder
        let active: RecorderProfileBox
    }

    private func makeHarness(zone: TimeZone = .gmt) throws -> Harness {
        let database = try AppDatabase.makeEmpty()
        var track = TrackRecord(filePath: "/fixtures/a.fake")
        track.title = "a"
        track.artistName = "artist-a"
        track.albumTitle = "Blue Album"
        track.genre = "Jazz"
        try database.writer.write { db in try track.insert(db) }

        let coordinator = PlayEventHarness().coordinator
        let active = RecorderProfileBox(ProfileRecord.guestID)
        let recorder = PlayEventRecorder(
            events: PlayEventRepository(database),
            tracks: TrackRepository(database),
            activeProfileId: { active.id },
            timeZone: zone
        )
        coordinator.onTrackStarted = { _ in recorder.trackDidStart() }
        coordinator.onPlayEvent = { recorder.record($0) }
        return Harness(database: database, coordinator: coordinator, recorder: recorder, active: active)
    }

    private func storedEvents(
        _ harness: Harness,
        profileId: Int64 = ProfileRecord.guestID
    ) async throws -> [PlayEventRecord] {
        await harness.recorder.flushAndWait()
        return try await PlayEventRepository(harness.database)
            .playEvents(profileId: profileId, before: nil, limit: 100)
            .items
    }

    private func makeSecondProfile(_ harness: Harness) throws -> Int64 {
        let created = try ProfileRepository(harness.database).create(ProfileRecord(name: "P2"))
        return try #require(created.id)
    }

    private func libraryTrack() -> TrackRef {
        PlayEventHarness.track("a", id: seededTrackId)
    }

    // MARK: Emission + derived statistics

    @Test("a natural end records one completed, unskipped play")
    func naturalEndRecordsCompletedPlay() async throws {
        let harness = try makeHarness()
        harness.coordinator.setQueue([libraryTrack(), .fixture("b")], startingAt: 0)

        harness.coordinator.handleTrackDidFinish()

        let events = try await storedEvents(harness)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.skipped == false)
        #expect(event.completionFraction == 1)
        #expect(event.secondsListened == PlayEventHarness.trackDuration)
    }

    @Test("next() one fifth of the way in records a skip")
    func userNextEarlyRecordsSkip() async throws {
        let harness = try makeHarness()
        harness.coordinator.setQueue([libraryTrack(), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 20)

        harness.coordinator.next()

        let events = try await storedEvents(harness)
        let event = try #require(events.first)
        #expect(event.skipped)
        #expect(event.completionFraction == 0.2)
    }

    @Test("next() past the halfway mark is not a skip")
    func userNextLateIsNotSkip() async throws {
        let harness = try makeHarness()
        harness.coordinator.setQueue([libraryTrack(), .fixture("b")], startingAt: 0)
        harness.coordinator.seek(to: 80)

        harness.coordinator.next()

        let events = try await storedEvents(harness)
        let event = try #require(events.first)
        #expect(event.skipped == false)
    }

    @Test("a transition with nothing heard yet records no event at all")
    func zeroElapsedRecordsNothing() async throws {
        let harness = try makeHarness()
        harness.coordinator.setQueue([libraryTrack(), .fixture("b")], startingAt: 0)

        harness.coordinator.next()

        let events = try await storedEvents(harness)
        #expect(events.isEmpty)
    }

    @Test("an unknown duration records a zero completion and no skip verdict")
    func unknownDurationIsNeverNaN() async throws {
        let harness = try makeHarness()
        harness.recorder.record(.probe(reason: .userNext, elapsed: 30, duration: 0))

        let events = try await storedEvents(harness)
        let event = try #require(events.first)
        #expect(event.durationSeconds == nil)
        #expect(event.completionFraction == 0)
        #expect(event.skipped == false)
        #expect(event.secondsListened == 30)
    }

    // MARK: Capture-time metadata

    @Test("album and genre are read from the library, title and artist from the signal")
    func metadataIsSnapshotAtCapture() async throws {
        let harness = try makeHarness()
        harness.coordinator.setQueue([libraryTrack()], startingAt: 0)
        harness.coordinator.seek(to: 40)

        harness.coordinator.stop()

        let events = try await storedEvents(harness)
        let event = try #require(events.first)
        #expect(event.trackId == seededTrackId)
        #expect(event.title == "a")
        #expect(event.artistName == "artist-a")
        #expect(event.albumTitle == "Blue Album")
        #expect(event.genre == "Jazz")
    }

    @Test("a non-library play records a nil trackId but keeps its title and artist")
    func nonLibraryPlayRecordsNilTrackId() async throws {
        let harness = try makeHarness()
        harness.recorder.record(.probe(reason: .stopped, elapsed: 12, trackId: nil))

        let events = try await storedEvents(harness)
        let event = try #require(events.first)
        #expect(event.trackId == nil)
        #expect(event.title == "probe")
        #expect(event.artistName == "probe-artist")
        #expect(event.albumTitle == nil)
        #expect(event.genre == nil)
    }

    @Test("a trackId with no surviving row still records the signal's own metadata")
    func deletedTrackStillRecords() async throws {
        let harness = try makeHarness()
        harness.recorder.record(.probe(reason: .stopped, elapsed: 5, trackId: 9999))

        let events = try await storedEvents(harness)
        let event = try #require(events.first)
        #expect(event.trackId == 9999)
        #expect(event.title == "probe")
        #expect(event.genre == nil)
    }

    // MARK: Local-time context

    @Test("each event carries the injected zone's offset for its own instant across a DST boundary")
    func utcOffsetTracksDaylightSaving() async throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let harness = try makeHarness(zone: zone)

        harness.recorder.record(.probe(reason: .natural, elapsed: 10, startedAt: winterEpoch))
        harness.recorder.record(.probe(reason: .natural, elapsed: 10, startedAt: summerEpoch))

        let events = try await storedEvents(harness)
        let offsets = events.sorted { $0.startedAt < $1.startedAt }.map(\.utcOffsetSeconds)
        #expect(offsets == [-5 * 3600, -4 * 3600])
    }

    // MARK: Attribution

    @Test("the event is attributed to the profile that was active when the track STARTED")
    func attributionIsHeldFromTrackStart() async throws {
        let harness = try makeHarness()
        let second = try makeSecondProfile(harness)
        harness.coordinator.setQueue([libraryTrack()], startingAt: 0)
        harness.coordinator.seek(to: 40)

        // Exactly what `ProfileService.activate` does: the active profile flips
        // BEFORE the switch effects run, so a live read here would be wrong.
        harness.active.id = second
        harness.coordinator.stopForProfileSwitch()

        let outgoing = try await storedEvents(harness, profileId: ProfileRecord.guestID)
        let incoming = try await storedEvents(harness, profileId: second)
        #expect(outgoing.count == 1)
        #expect(incoming.isEmpty)
    }

    @Test("stopForProfileSwitch records the interrupted play as a profile switch, not a stop")
    func profileSwitchClearsAndRecordsOnce() async throws {
        let harness = try makeHarness()
        let spy = PlayEventSpy()
        harness.coordinator.onPlayEvent = { [recorder = harness.recorder] signal in
            spy.record(signal)
            recorder.record(signal)
        }
        harness.coordinator.setQueue([libraryTrack()], startingAt: 0)
        harness.coordinator.seek(to: 25)

        harness.coordinator.stopForProfileSwitch()

        #expect(spy.reasons == [.profileSwitch])
        #expect(harness.coordinator.queue.isEmpty)
        let events = try await storedEvents(harness)
        #expect(events.count == 1)
    }

    @Test("rescope re-points attribution for plays that follow a switch")
    func rescopeRepointsAttribution() async throws {
        let harness = try makeHarness()
        let second = try makeSecondProfile(harness)

        harness.recorder.rescope(to: second)
        harness.recorder.record(.probe(reason: .stopped, elapsed: 8))

        let incoming = try await storedEvents(harness, profileId: second)
        let outgoing = try await storedEvents(harness, profileId: ProfileRecord.guestID)
        #expect(incoming.count == 1)
        #expect(outgoing.isEmpty)
    }
}

private extension PlayEventSignal {
    /// A signal built directly, for the cases a coordinator cannot stage.
    static func probe(
        reason: PlayEndReason,
        elapsed: Double,
        duration: Double = probeDuration,
        startedAt: Double = probeEpoch,
        trackId: Int64? = seededTrackId
    ) -> PlayEventSignal {
        PlayEventSignal(
            outgoingTrackId: trackId,
            title: "probe",
            artist: "probe-artist",
            startedAt: startedAt,
            elapsedSeconds: elapsed,
            durationSeconds: duration,
            reason: reason
        )
    }
}
