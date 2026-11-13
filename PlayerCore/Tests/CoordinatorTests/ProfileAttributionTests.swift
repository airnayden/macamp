// Profile-attribution + listen-timer-across-switch behaviour for the playback
// progress hooks (Task 10): each hook resolves the active profile at FIRE time,
// and a stop/clear (the coordinator primitive Task 11 invokes before flipping the
// active profile) cancels the listen timer so it cannot credit the wrong profile
// across a switch boundary.
//
// The play-event recorder joins the same seam (Task 3): its attribution is HELD
// from the track's start rather than resolved at fire time, because a switch flips
// `activeProfile` before the effects run — so the two policies are asserted side by
// side here, against the same switch boundary.
import AudioEngine
import Foundation
import GRDB
import Persistence
@testable import Services
import Testing

/// Mutable, main-actor stand-in for `ProfileService.activeProfile.id` so a test
/// can flip the "active profile" between hook fires.
@MainActor
private final class ActiveProfileBox {
    var id: Int64
    init(_ id: Int64) {
        self.id = id
    }
}

@MainActor
@Suite("ProfileAttributionTests", .serialized)
struct ProfileAttributionTests {
    private struct Harness {
        let appDB: AppDatabase
        let repo: TrackRepository
        let coordinator: PlaybackCoordinator
        let trackId: Int64
        let profile2Id: Int64
    }

    private func makeHarness(listenThreshold: Duration) throws -> Harness {
        let appDB = try AppDatabase.makeEmpty()
        let profile2 = try ProfileRepository(appDB).create(ProfileRecord(name: "P2"))
        let profile2Id = try #require(profile2.id)
        var track = TrackRecord(filePath: "/music/a.flac")
        try appDB.writer.write { db in try track.insert(db) }
        let trackId = try #require(track.id)
        let coordinator = PlaybackCoordinator.fake()
        coordinator.listenThreshold = listenThreshold
        return Harness(
            appDB: appDB,
            repo: TrackRepository(appDB),
            coordinator: coordinator,
            trackId: trackId,
            profile2Id: profile2Id
        )
    }

    private func wireHooks(_ coordinator: PlaybackCoordinator, repo: TrackRepository, active: ActiveProfileBox) {
        coordinator.onTrackStarted = { trackId in
            guard trackId > 0 else { return }
            let profileId = active.id
            Task { try? await repo.incrementPlayCount(profileId: profileId, trackId: trackId) }
        }
        coordinator.onTrackListened = { trackId in
            guard trackId > 0 else { return }
            let profileId = active.id
            Task { try? await repo.incrementListenedCount(profileId: profileId, trackId: trackId) }
        }
    }

    private func playCount(_ harness: Harness, profileId: Int64) throws -> Int? {
        try harness.repo.resolvedTrack(profileId: profileId, trackId: harness.trackId)?.playCount
    }

    private func listenedCount(_ harness: Harness, profileId: Int64) throws -> Int? {
        try harness.repo.resolvedTrack(profileId: profileId, trackId: harness.trackId)?.listenedCount
    }

    private func poll(
        timeout: Duration = .seconds(2),
        until condition: @MainActor () throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try condition()
    }

    @Test("a stop before the listen threshold (profile switch) credits no listen for any profile")
    func stopBeforeThresholdCancelsListen() async throws {
        let harness = try makeHarness(listenThreshold: .milliseconds(100))
        let active = ActiveProfileBox(ProfileRecord.guestID)
        wireHooks(harness.coordinator, repo: harness.repo, active: active)

        let ref = TrackRef(trackID: harness.trackId, filePath: "/fixtures/a.fake", title: "a")
        harness.coordinator.setQueue([ref], startingAt: 0)
        harness.coordinator.stop()
        active.id = harness.profile2Id

        let started = try await poll { try playCount(harness, profileId: ProfileRecord.guestID) == 1 }
        #expect(started)
        #expect(harness.coordinator.state.playback == .stopped)

        try await Task.sleep(for: .milliseconds(300))
        try #expect(listenedCount(harness, profileId: ProfileRecord.guestID) == 0)
        try #expect(listenedCount(harness, profileId: harness.profile2Id) == 0)
    }

    @Test("playing past the listen threshold without switching credits only the active profile")
    func listenPastThresholdCreditsActiveProfileOnly() async throws {
        let harness = try makeHarness(listenThreshold: .milliseconds(100))
        let active = ActiveProfileBox(ProfileRecord.guestID)
        wireHooks(harness.coordinator, repo: harness.repo, active: active)

        let ref = TrackRef(trackID: harness.trackId, filePath: "/fixtures/a.fake", title: "a")
        harness.coordinator.setQueue([ref], startingAt: 0)

        let listened = try await poll { try listenedCount(harness, profileId: ProfileRecord.guestID) == 1 }
        #expect(listened)
        try #expect(listenedCount(harness, profileId: harness.profile2Id) == 0)
        try #expect(playCount(harness, profileId: ProfileRecord.guestID) == 1)
    }

    @Test("a profile switch mid-track files the partial play under the OUTGOING profile")
    func switchMidTrackAttributesPartialPlayToOutgoingProfile() async throws {
        let harness = try makeHarness(listenThreshold: .seconds(60))
        let active = ActiveProfileBox(ProfileRecord.guestID)
        wireHooks(harness.coordinator, repo: harness.repo, active: active)
        let recorder = PlayEventRecorder(
            events: PlayEventRepository(harness.appDB),
            tracks: harness.repo,
            activeProfileId: { active.id },
            timeZone: .gmt
        )
        let started = harness.coordinator.onTrackStarted
        harness.coordinator.onTrackStarted = { trackId in
            started?(trackId)
            recorder.trackDidStart()
        }
        harness.coordinator.onPlayEvent = { recorder.record($0) }

        let ref = TrackRef(trackID: harness.trackId, filePath: "/fixtures/a.fake", title: "a")
        harness.coordinator.setQueue([ref], startingAt: 0)
        harness.coordinator.seek(to: 0.4)
        active.id = harness.profile2Id
        harness.coordinator.stopForProfileSwitch()
        await recorder.flushAndWait()

        let events = PlayEventRepository(harness.appDB)
        let outgoing = try await events.playEvents(profileId: ProfileRecord.guestID, before: nil, limit: 10)
        let incoming = try await events.playEvents(profileId: harness.profile2Id, before: nil, limit: 10)
        #expect(outgoing.items.count == 1)
        #expect(incoming.items.isEmpty)
        let event = try #require(outgoing.items.first)
        #expect(event.secondsListened == 0.4)
        #expect(event.skipped == false)
        #expect(harness.coordinator.queue.isEmpty)
    }

    @Test("progress hooks resolve the active profile at fire time, not at wiring time")
    func hooksResolveProfileAtFireTime() async throws {
        let harness = try makeHarness(listenThreshold: .seconds(60))
        let active = ActiveProfileBox(ProfileRecord.guestID)
        wireHooks(harness.coordinator, repo: harness.repo, active: active)

        harness.coordinator.onTrackStarted?(harness.trackId)
        let firstCredited = try await poll { try playCount(harness, profileId: ProfileRecord.guestID) == 1 }
        #expect(firstCredited)

        active.id = harness.profile2Id
        harness.coordinator.onTrackStarted?(harness.trackId)
        let secondCredited = try await poll { try playCount(harness, profileId: harness.profile2Id) == 1 }
        #expect(secondCredited)

        try #expect(playCount(harness, profileId: ProfileRecord.guestID) == 1)
    }
}
