// PlayEventRecorder — turns coordinator play-event signals into durable history.
//
// The coordinator emits ONE ``PlayEventSignal`` per real transition (see
// `PlaybackCoordinator+PlayEvent.swift`). This type is the only consumer that
// writes them down: it stamps the capture-time local UTC offset, resolves the two
// denormalised fields the signal cannot carry (genre + album), and appends a
// `playEvent` row off the main actor.
//
// Three rules are load-bearing and easy to break:
//
//  1. **Attribution is HELD, never re-read.** The owning profile is captured when
//     the track STARTS and stamped onto the OUTGOING event at emit time.
//     `ProfileService.activate` flips `activeProfile` BEFORE it fires
//     `onActiveProfileChanged`, so a live read during a switch would already see
//     the incoming profile and mis-file the play that just ended.
//  2. **Only plays that actually made sound are recorded.** A load-while-paused
//     still fires `onTrackStarted`, so the emission guard is `elapsed > 0` rather
//     than "a signal arrived".
//  3. **Nothing here may touch the audio thread.** Every database access runs in a
//     detached task; the main actor only composes value types.
//
// This file imports only Foundation + Persistence; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import Foundation
import Persistence

/// Records completed plays into the per-profile listening history.
///
/// Class-bound + `@MainActor`: every entry point is called from the coordinator's
/// main-actor hooks, and the held attribution id is main-actor state.
@MainActor
public protocol PlayEventRecording: AnyObject {
    /// Captures the profile that owns the play now beginning.
    ///
    /// Call this from `PlaybackCoordinator.onTrackStarted` — BEFORE any
    /// `trackId > 0` filtering, so a non-library play is attributed too.
    func trackDidStart()

    /// Records `signal` as one row of listening history.
    ///
    /// Returns immediately; the write is enqueued off-main. Use
    /// ``flushAndWait()`` to await it.
    func record(_ signal: PlayEventSignal)

    /// Re-points attribution at `profileId`.
    ///
    /// A profile switch restores the incoming profile's queue, and restore never
    /// fires `onTrackStarted` — so without this the held id would stay on the
    /// outgoing profile. Call it AFTER the outgoing play has been flushed.
    func rescope(to profileId: Int64)

    /// Awaits every write enqueued so far. Called at quit.
    func flushAndWait() async
}

/// The production ``PlayEventRecording`` over the v15 `playEvent` table.
@MainActor
public final class PlayEventRecorder: PlayEventRecording {
    /// The transitions that mean the listener cut the track short. A natural end,
    /// a `stop`, and a profile switch are never skips — the first finished, and
    /// the other two are not judgements about the track.
    private static let skipReasons: Set<PlayEndReason> = [.userNext, .userPrevious, .jump]
    /// Below this share of the track, a user-driven transition counts as a skip.
    private static let skipThreshold = 0.5

    private let events: any PlayEventRepositoryProviding
    private let tracks: any TrackRepositoryProviding
    private let activeProfileId: @MainActor () -> Int64
    private let timeZone: TimeZone

    /// The profile that owns the play currently in flight. Seeded at wiring time
    /// (a restored session never fires `onTrackStarted`), refreshed on every
    /// track start, and re-pointed by ``rescope(to:)``.
    private var attributionProfileId: Int64
    /// Tail of the serial write chain; awaiting it awaits everything before it.
    private var tail: Task<Void, Never>?

    /// - Parameters:
    ///   - events: The v15 listening-history writer.
    ///   - tracks: Read side for the two denormalised fields the signal omits.
    ///   - activeProfileId: Resolves the active profile. Read at construction and
    ///     at each track start — never at emit time.
    ///   - timeZone: The zone whose offset is stamped on each event. Injected so
    ///     tests can pin a DST-crossing zone.
    public init(
        events: any PlayEventRepositoryProviding,
        tracks: any TrackRepositoryProviding,
        activeProfileId: @escaping @MainActor () -> Int64,
        timeZone: TimeZone = .current
    ) {
        self.events = events
        self.tracks = tracks
        self.activeProfileId = activeProfileId
        self.timeZone = timeZone
        attributionProfileId = activeProfileId()
    }

    public func trackDidStart() {
        attributionProfileId = activeProfileId()
    }

    public func rescope(to profileId: Int64) {
        attributionProfileId = profileId
    }

    public func record(_ signal: PlayEventSignal) {
        // A track that never played produced no listening history: a
        // load-while-paused, or a transition away from a queue position that was
        // loaded but never started, must not leave a zero-second row behind.
        guard signal.elapsedSeconds > 0 else { return }
        let event = makeEvent(from: signal)
        let events = events
        let tracks = tracks
        enqueue {
            let resolved = await Self.resolvingMetadata(event, in: tracks)
            try? await events.insertPlayEvent(resolved)
        }
    }

    public func flushAndWait() async {
        await tail?.value
    }
}

// MARK: - Composition

private extension PlayEventRecorder {
    /// Builds everything the signal already knows, plus the derived statistics.
    ///
    /// A duration of zero is a real state (an unknown-length source), NOT a
    /// divide-by-zero to guess around: completion stays `0` so no `NaN`/`Inf` can
    /// ever reach the database, and `skipped` stays `false` because with no length
    /// there is nothing to have cut short.
    func makeEvent(from signal: PlayEventSignal) -> PlayEventRecord {
        let duration = signal.durationSeconds
        let hasDuration = duration > 0
        let completion = hasDuration ? min(1, max(0, signal.elapsedSeconds / duration)) : 0
        let skipped = hasDuration
            && Self.skipReasons.contains(signal.reason)
            && completion < Self.skipThreshold
        return PlayEventRecord(
            profileId: attributionProfileId,
            trackId: signal.outgoingTrackId,
            artistName: signal.artist,
            title: signal.title,
            durationSeconds: hasDuration ? duration : nil,
            startedAt: signal.startedAt,
            utcOffsetSeconds: utcOffsetSeconds(at: signal.startedAt),
            secondsListened: signal.elapsedSeconds,
            completionFraction: completion,
            skipped: skipped,
            sourceSurface: signal.sourceSurface,
            shuffle: signal.shuffle
        )
    }

    /// The zone's offset **for this event's own instant**, so a history spanning a
    /// daylight-saving boundary reports each play in the local hour it happened.
    func utcOffsetSeconds(at startedAt: TimeInterval) -> Int {
        timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: startedAt))
    }

    /// Chains `work` behind everything already enqueued.
    ///
    /// Serial by construction, so history lands in emission order and
    /// ``flushAndWait()`` only has to await the tail. Detached because the work
    /// hits the database and must never run on the main actor.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task.detached(priority: .utility) {
            await previous?.value
            await work()
        }
    }

    /// Fills in the two fields ``TrackRef`` deliberately does not carry.
    ///
    /// `TrackRef` stays DB-free so the playback hot path never touches SQLite;
    /// album and genre are therefore read here, once, off-main. A non-library play
    /// (`trackId == nil`) keeps its title/artist and simply has neither.
    nonisolated static func resolvingMetadata(
        _ event: PlayEventRecord,
        in tracks: any TrackRepositoryProviding
    ) async -> PlayEventRecord {
        guard let trackId = event.trackId else { return event }
        let stored = await Task.detached(priority: .utility) {
            try? tracks.fetchTrack(id: trackId)
        }.value
        guard let stored else { return event }
        var resolved = event
        resolved.albumTitle = stored.albumTitle
        resolved.genre = stored.genre
        return resolved
    }
}
