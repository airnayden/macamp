// The download queue is PROFILE-AGNOSTIC, and this suite is what makes that claim
// testable rather than merely asserted in a comment.
//
// The plan deliberately gives a profile switch no orchestrator step: nothing re-plumbs
// the queue, nothing rescopes it, nothing cancels it. A download the listener started
// under one profile finishes under whichever profile is active when it lands, and the
// file it produces is ownerless — so it is visible to all of them either way.
//
// The switch is driven through the REAL `ProfileService`, not a fake: the invariant being
// pinned is that the shipped switch path has no reachable edge into the queue, and a
// double could only demonstrate that about itself.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("Download queue survives a profile switch")
struct DownloadProfileSwitchTests {
    /// Switches profiles at the first `.downloading` tick and asserts the in-flight row
    /// is the same row afterwards, and that it still completes.
    ///
    /// Deterministic with no sleeps: the driver awaits each progress publication, so the
    /// switch has fully landed before the next engine line is read
    /// (`DownloadQueueHarness.interruptOnFirstDownloadTick`'s guarantee).
    @Test("switching profiles mid-download leaves the in-flight item untouched")
    func profileSwitchLeavesTheInFlightItemUntouched() async throws {
        let profiles = try DownloadProfileFixture.make()
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
        ])
        let observed = DownloadSwitchObservation()
        // The in-flight row is read through the PUBLISHED snapshot, not a peek at the
        // service's internals — the seam is the only thing an observer of a real switch
        // would have, so asserting on it is the honest form of "untouched".
        let recorder = harness.recorder
        harness.interruptOnFirstDownloadTick { _ in
            observed.recordBeforeSwitch(recorder.latestSnapshot.activeItems.first?.id)
            try? profiles.service.switchTo(profileId: profiles.secondProfileID, pin: nil)
            observed.recordAfterSwitch(recorder.latestSnapshot.activeItems.first?.id)
        }
        let url = try downloadTestURL(DownloadFixture.watchURL)

        _ = await harness.service.enqueue(urls: [url])
        await harness.waitForTerminals(1)

        let before = try #require(observed.beforeSwitch)
        #expect(observed.afterSwitch == before)
        #expect(profiles.service.activeProfile.id == profiles.secondProfileID)
        let finishedURL = URL(fileURLWithPath: DownloadFixture.finishedPath)
        #expect(harness.recorder.states(of: before).last == .finished(fileURL: finishedURL))
        #expect(harness.recorder.finished.count == 1)
    }

    /// The queue keeps running after the switch, not merely the row that was already in
    /// flight: a second row queued behind it is dequeued and completed under the NEW
    /// active profile.
    @Test("a row queued behind the switch still runs afterwards")
    func queuedRowStillRunsAfterTheSwitch() async throws {
        let profiles = try DownloadProfileFixture.make()
        let harness = DownloadQueueHarness(scripts: [
            DownloadFixture.infoScript(),
            DownloadFixture.happyDownloadScript,
            DownloadFixture.infoScript(id: DownloadFixture.otherVideoID),
            DownloadFixture.happyDownloadScript,
        ])
        harness.interruptOnFirstDownloadTick { _ in
            try? profiles.service.switchTo(profileId: profiles.secondProfileID, pin: nil)
        }
        let urls = try [
            downloadTestURL(DownloadFixture.watchURL),
            downloadTestURL(DownloadFixture.otherWatchURL),
        ]

        _ = await harness.service.enqueue(urls: urls)
        await harness.waitForTerminals(2)

        #expect(harness.recorder.finished.count == 2)
        #expect(harness.recorder.latestSnapshot == .empty)
    }
}

/// The two ids observed around the switch. Lock-guarded because the seam that writes it
/// is `@Sendable` by contract.
final class DownloadSwitchObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var before: UUID?
    private var after: UUID?

    func recordBeforeSwitch(_ id: UUID?) {
        lock.withLock { before = id }
    }

    func recordAfterSwitch(_ id: UUID?) {
        lock.withLock { after = id }
    }

    var beforeSwitch: UUID? {
        lock.withLock { before }
    }

    var afterSwitch: UUID? {
        lock.withLock { after }
    }
}

/// A real `ProfileService` over a migrated in-memory database, with a second, PIN-less
/// profile to switch to.
///
/// The `UserDefaults` suite is per-fixture so the persisted active-profile id cannot leak
/// between tests (or into the developer's own defaults).
@MainActor
struct DownloadProfileFixture {
    let service: ProfileService
    let secondProfileID: Int64

    static func make() throws -> DownloadProfileFixture {
        let database = try AppDatabase.makeEmpty()
        let repository = ProfileRepository(database)
        let second = try repository.create(ProfileRecord(
            name: "Second",
            lastName: nil,
            bio: nil,
            avatarId: "waveform-vice",
            pinHash: nil,
            pinSalt: nil,
            createdAt: Date()
        ))
        let suite = "com.example.macamp.tests.downloads.profiles.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DownloadLibraryFixtureError.defaultsSuiteUnavailable(suite)
        }
        guard let secondProfileID = second.id else { throw DownloadLibraryFixtureError.profileHasNoID }
        let service = ProfileService(profileRepository: repository, defaults: defaults)
        return DownloadProfileFixture(service: service, secondProfileID: secondProfileID)
    }
}
