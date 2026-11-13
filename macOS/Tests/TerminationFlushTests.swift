// TerminationFlushTests — the quit path actually waits for the history write.
//
// This suite lives in the macOS app test target rather than the PlayerCore package
// because `applicationShouldTerminate` is an `NSApplicationDelegate` hook: `swift
// test` cannot reach it at all.
//
// The delegate is driven through `beginTermination(reply:)` rather than
// `applicationShouldTerminate(_:)` — the latter would send a real
// `reply(toApplicationShouldTerminate:)` to `NSApp` and terminate the test host.
//
// ── HOW THIS SUITE WAITS, AND WHY IT IS NOT A SLEEP ──────────────────────────
//
// Every stage of the quit path is asynchronous (a detached GRDB write, a race
// against a deadline, an AppKit reply drained a hop later), so each assertion has
// to be fenced behind the thing it is about. Fixed `settle()` sleeps used to do
// that job and were LOAD-SENSITIVE: at load average 130-170 this suite failed
// 3 runs in 14, on four different assertion lines across two tests, always
// because an off-main write had not landed inside 50 ms.
//
// So a positive assertion now fences on a REAL completion signal — a
// ``FlushBarrier`` the flush itself opens, or ``ReplyRecorder/waitForReplies(_:)``
// — never on elapsed time. `settle()` survives only for NEGATIVE-space checks,
// where there is no completion to await because the point is that nothing runs.
import AppKit
import AudioEngine
import Foundation
import GRDB
@testable import MacAMP
import Models
import Persistence
import Services
import Testing

/// A one-shot main-actor latch: `open()` releases every waiter, and any later
/// `wait()` returns immediately.
///
/// Used in BOTH directions, which is the whole synchronisation strategy here:
///   * as a GATE the TEST opens by hand, so a flush can be observed mid-flight;
///   * as a COMPLETION SIGNAL the FLUSH opens and the test awaits, which is what
///     replaced the fixed sleeps.
@MainActor
private final class FlushBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let resumable = waiters
        waiters.removeAll()
        for waiter in resumable {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor
private final class ReplyRecorder {
    private struct Waiter {
        let needed: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var replies: [Bool] = []
    private var waiters: [Waiter] = []

    func record(_ allowed: Bool) {
        replies.append(allowed)
        let landed = replies.count
        let resumable = waiters.filter { $0.needed <= landed }
        waiters.removeAll { $0.needed <= landed }
        for waiter in resumable {
            waiter.continuation.resume()
        }
    }

    /// Resumes once `count` replies have landed.
    ///
    /// The delegate drains its replies a few hops after the flush returns, so this
    /// is the fence that replaces sleeping and hoping AppKit's reply arrived.
    func waitForReplies(_ count: Int) async {
        guard replies.count < count else { return }
        await withCheckedContinuation { waiters.append(Waiter(needed: count, continuation: $0)) }
    }
}

@MainActor
@Suite("TerminationFlushTests", .serialized)
struct TerminationFlushTests {
    @Test("with no flush installed the app terminates immediately")
    func nilHandlerTerminatesNow() async throws {
        let delegate = MenuPruningDelegate()
        let replies = ReplyRecorder()

        let verdict = delegate.beginTermination { replies.record($0) }

        #expect(verdict == .terminateNow)
        try await settle()
        #expect(replies.replies.isEmpty)
    }

    @Test("the reply waits for the history write, then lands once it commits")
    func replyWaitsForTheWrite() async throws {
        let database = try AppDatabase.makeEmpty()
        let recorder = Self.makeRecorder(database)
        let barrier = FlushBarrier()
        let entered = FlushBarrier()
        let flushed = FlushBarrier()
        let delegate = MenuPruningDelegate()
        let replies = ReplyRecorder()
        delegate.terminationFlushTimeout = Self.flushHeadroom
        delegate.terminationFlush = {
            entered.open()
            await barrier.wait()
            recorder.record(.terminationProbe)
            await recorder.flushAndWait()
            flushed.open()
        }

        let verdict = delegate.beginTermination { replies.record($0) }
        await entered.wait()

        #expect(verdict == .terminateLater)
        #expect(replies.replies.isEmpty)
        #expect(try await storedEventCount(database) == 0)

        barrier.open()
        await flushed.wait()
        await replies.waitForReplies(1)

        #expect(replies.replies == [true])
        #expect(try await storedEventCount(database) == 1)
    }

    @Test("the reply waits for BOTH the history write and the replay heatmap")
    func replyWaitsForBothStatsConsumers() async throws {
        let database = try AppDatabase.makeEmpty()
        let recorder = Self.makeRecorder(database)
        let tracker = Self.makeTracker(database)
        let historyBarrier = FlushBarrier()
        let heatBarrier = FlushBarrier()
        let entered = FlushBarrier()
        let historyFlushed = FlushBarrier()
        let heatFlushed = FlushBarrier()
        let delegate = MenuPruningDelegate()
        let replies = ReplyRecorder()
        delegate.terminationFlushTimeout = Self.flushHeadroom
        // The production handler's shape: the coordinator's synchronous emit, then
        // the recorder, then the tracker — a reply may not land until both commit.
        // Each stage opens its own signal the instant its `flushAndWait()` returns,
        // which is exactly when that consumer's row is committed and readable.
        delegate.terminationFlush = {
            entered.open()
            await historyBarrier.wait()
            recorder.record(.terminationProbe)
            await recorder.flushAndWait()
            historyFlushed.open()
            await heatBarrier.wait()
            Self.listenAndFlush(tracker)
            await tracker.flushAndWait()
            heatFlushed.open()
        }

        let verdict = delegate.beginTermination { replies.record($0) }
        await entered.wait()

        #expect(verdict == .terminateLater)
        #expect(replies.replies.isEmpty)

        historyBarrier.open()
        await historyFlushed.wait()

        #expect(try await storedEventCount(database) == 1)
        #expect(try await storedHeat(database) == nil)
        #expect(replies.replies.isEmpty)

        heatBarrier.open()
        await heatFlushed.wait()
        await replies.waitForReplies(1)

        let heat = try await storedHeat(database)
        #expect(try #require(heat).totalPasses == 1)
        #expect(replies.replies == [true])
    }

    @Test("a quit that stalls on the heatmap still replies once the timeout elapses")
    func timeoutRepliesWithBothConsumersGated() async {
        let historyBarrier = FlushBarrier()
        let heatBarrier = FlushBarrier()
        let delegate = MenuPruningDelegate()
        let replies = ReplyRecorder()
        delegate.terminationFlushTimeout = .milliseconds(100)
        delegate.terminationFlush = {
            await historyBarrier.wait()
            await heatBarrier.wait()
        }

        let verdict = delegate.beginTermination { replies.record($0) }
        // Both barriers stay shut, so the flush cannot be what replies: the only
        // thing that can resume this is the delegate's own deadline firing.
        await replies.waitForReplies(1)

        #expect(verdict == .terminateLater)
        #expect(replies.replies == [true])
        historyBarrier.open()
        heatBarrier.open()
    }

    @Test("a flush that never finishes still lets the app quit once the timeout elapses")
    func timeoutRepliesAnyway() async {
        let barrier = FlushBarrier()
        let delegate = MenuPruningDelegate()
        let replies = ReplyRecorder()
        delegate.terminationFlushTimeout = .milliseconds(100)
        delegate.terminationFlush = { await barrier.wait() }

        let verdict = delegate.beginTermination { replies.record($0) }
        await replies.waitForReplies(1)

        #expect(verdict == .terminateLater)
        #expect(replies.replies == [true])
        barrier.open()
    }

    @Test("a second terminate request joins the running flush instead of starting another")
    func duplicateRequestsShareOneFlush() async {
        let barrier = FlushBarrier()
        let delegate = MenuPruningDelegate()
        let replies = ReplyRecorder()
        let flushes = FlushCounter()
        delegate.terminationFlushTimeout = Self.flushHeadroom
        delegate.terminationFlush = {
            flushes.increment()
            await barrier.wait()
        }

        let first = delegate.beginTermination { replies.record($0) }
        let second = delegate.beginTermination { replies.record($0) }
        barrier.open()
        await replies.waitForReplies(2)

        #expect(first == .terminateLater)
        #expect(second == .terminateLater)
        #expect(flushes.count == 1)
        #expect(replies.replies == [true, true])
    }

    @Test("the persister no longer writes on NSApplication.willTerminateNotification")
    func persisterIgnoresWillTerminate() async throws {
        let harness = try PlaybackStateTestHarness(debounceInterval: .seconds(60))
        defer { harness.cleanUp() }
        harness.replaceQueue(source: .favourites)
        harness.coordinator.seek(to: 12)
        harness.persister.cancelPending()

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        try await settle()

        #expect(try await harness.record(for: ProfileRecord.guestID) == nil)

        await harness.persister.flushAtTermination()

        #expect(try await harness.record(for: ProfileRecord.guestID) != nil)
    }
}

// MARK: - Fixtures

/// Suite fixtures, in an extension so they do not count against the suite's
/// `type_body_length` budget.
private extension TerminationFlushTests {
    /// A deadline no test run can reach, so the delegate's race is decided by the
    /// FLUSH rather than by the clock.
    ///
    /// Every test here parks the flush on a barrier it opens by hand, so the
    /// shipping 2 s default would be racing the TEST, not the flush — and on a
    /// loaded host it wins, replying while a stats write is still in flight and
    /// making `replies.isEmpty` fail for a reason the test is not about. It stays
    /// FINITE on purpose: if the production path ever stops replying, the deadline
    /// still fires and these tests go red instead of hanging. The deadline
    /// behaviour itself has its own two cases, which set their own 100 ms.
    static let flushHeadroom: Duration = .seconds(30)

    /// Gives a path that should do NOTHING a chance to do something.
    ///
    /// The only honest use of a fixed wait in this suite: there is no completion to
    /// fence on when the assertion is that no work was scheduled at all. Never use
    /// it before a positive assertion — that is the load-sensitive pattern this
    /// suite was rewritten to remove.
    func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    func storedEventCount(_ database: AppDatabase) async throws -> Int {
        try await PlayEventRepository(database)
            .playEvents(profileId: ProfileRecord.guestID, before: nil, limit: 10)
            .items
            .count
    }

    func storedHeat(_ database: AppDatabase) async throws -> PlaySegmentHeatRecord? {
        try await PlaySegmentHeatRepository(database)
            .segmentHeat(profileId: ProfileRecord.guestID, trackId: Self.probeTrackId)
    }

    static let probeTrackId: Int64 = 4242

    static func makeRecorder(_ database: AppDatabase) -> PlayEventRecorder {
        PlayEventRecorder(
            events: PlayEventRepository(database),
            tracks: TrackRepository(database),
            activeProfileId: { ProfileRecord.guestID },
            timeZone: .gmt
        )
    }

    static func makeTracker(_ database: AppDatabase) -> PlaySegmentTracker {
        PlaySegmentTracker(
            heat: PlaySegmentHeatRepository(database),
            tracks: TrackRepository(database),
            playhead: PlaySegmentPlayhead(
                currentTrack: { Self.probeTrack },
                currentTime: { 0 },
                activeProfileId: { ProfileRecord.guestID }
            )
        )
    }

    static let probeTrack = TrackRef(
        trackID: probeTrackId,
        filePath: "/fixtures/quit-probe.fake",
        title: "quit-probe",
        artist: "quit-artist",
        duration: 100
    )

    static func listenAndFlush(_ tracker: PlaySegmentTracker) {
        tracker.beginTrack(trackRef: probeTrack, profileId: ProfileRecord.guestID)
        var time: TimeInterval = 0
        while time <= 20 {
            tracker.ingest(sample: PlayheadSample(time: time, isPlaying: true))
            time += PlaySegmentTracker.sampleInterval
        }
        tracker.flush(signal: .terminationProbe)
    }
}

@MainActor
private final class FlushCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private extension PlayEventSignal {
    static let terminationProbe = PlayEventSignal(
        outgoingTrackId: nil,
        title: "quit-probe",
        artist: "quit-artist",
        startedAt: 1_700_000_000,
        elapsedSeconds: 42,
        durationSeconds: 100,
        reason: .stopped
    )
}
