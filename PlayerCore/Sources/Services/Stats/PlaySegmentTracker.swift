// PlaySegmentTracker — turns the playhead into a per-track replay heatmap.
//
// The question this answers is not "did you play this song" (the play-event log
// already knows) but "which PARTS of it do you go back to" — YouTube's
// most-replayed graph, per profile, per track.
//
// The shape is deliberate: a PURE-LOGIC core (`ingest(sample:)`, `noteSeek`,
// `flush`) with a thin 1 Hz main-actor timer shell around it. Every rule below is
// therefore provable from a test that feeds samples by hand, with no timer, no
// coordinator and no clock.
//
// Four rules are load-bearing:
//
//  1. **Never the audio thread.** Sampling reads the engine's main-actor
//     `currentTime` property on a 1 Hz timer that exists ONLY while playing. Paused
//     or stopped, there is no timer at all (the idle-CPU ≈ 0% contract).
//  2. **Only `flush` commits.** Listened ranges accumulate in memory across pauses
//     and seeks; a single coordinator `PlayEventSignal` closes the open range and
//     writes the whole pass once.
//  3. **Flush detaches synchronously.** It snapshots and CLEARS the active identity
//     and pending ranges on the main actor BEFORE launching the write, so the next
//     track can never contaminate an in-flight commit.
//  4. **Identity is snapshotted, never joined.** The heatmap row carries the
//     artist/title/album/genre it was captured with, so it survives the track row.
//
// This file imports only Foundation + Persistence; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import Foundation
import Persistence

/// Captures which parts of a track a profile actually listens to.
///
/// Class-bound + `@MainActor`: every entry point is called from the coordinator's
/// main-actor hooks, and the open listen is main-actor state.
@MainActor
public protocol PlaySegmentTracking: AnyObject {
    /// Starts capturing for `trackRef`. Call from `PlaybackCoordinator.onTrackStarted`.
    ///
    /// A ref with no library id or no known duration begins nothing — those are the
    /// two cases a relative heatmap cannot describe.
    func beginTrack(trackRef: TrackRef, profileId: Int64)

    /// Folds one playhead reading into the open listen.
    func ingest(sample: PlayheadSample)

    /// Records a user seek: the open listen ends at `origin`, a new one opens at `target`.
    ///
    /// Call from `PlaybackCoordinator.onSeek`, the single user-seek choke point.
    func noteSeek(from origin: TimeInterval, to target: TimeInterval)

    /// Starts or stops sampling, delivering the boundary sample either way.
    func playbackStateDidChange(isPlaying: Bool)

    /// Closes the open listen and COMMITS the whole pass. Call from `onPlayEvent`.
    func flush(signal: PlayEventSignal)

    /// Re-points attribution at `profileId` after a profile switch.
    func rescope(to profileId: Int64)

    /// Awaits every commit enqueued so far. Called at quit.
    func flushAndWait() async
}

/// The production ``PlaySegmentTracking`` over the v15 `playSegmentHeat` table.
@MainActor
public final class PlaySegmentTracker: PlaySegmentTracking {
    /// Playhead sampling cadence while playing.
    public static let sampleInterval: TimeInterval = 1.0
    /// Consecutive readings at least this far apart still belong to one listen —
    /// below it the readings are duplicates, not progress.
    static let minimumStep: TimeInterval = 0.25
    /// Beyond this gap the playhead jumped (an external seek, a track change), so the
    /// listen is closed and a new one opened wherever the playhead now is.
    static let maximumStep: TimeInterval = 2.0
    /// How close to the end an open listen must already be for a natural end to
    /// complete it. Wide enough to absorb the final partial tick, far too narrow to
    /// reach a spurious range opened at a gapless successor's ~0 s position.
    static let naturalExtendTolerance: TimeInterval = 2.5

    /// The track a listen is currently being accrued for. Only ever set for a
    /// library track of known length — the two guard rails, enforced at the source.
    fileprivate struct ActiveTrack {
        var trackId: Int64
        var profileId: Int64
        var identity: PlaySegmentIdentity
    }

    private let heat: any PlaySegmentHeatRepositoryProviding
    private let tracks: any TrackRepositoryProviding
    private let playhead: PlaySegmentPlayhead
    private let now: @Sendable () -> TimeInterval

    /// The profile that owns the listen in flight. Seeded at construction (a restored
    /// session never fires `onTrackStarted`), refreshed on every track start, and
    /// re-pointed by ``rescope(to:)``.
    private var attributionProfileId: Int64
    private var active: ActiveTrack?
    private var pending: [PlaySegmentRange] = []
    private var openStart: TimeInterval?
    private var openEnd: TimeInterval?
    private var samplingTask: Task<Void, Never>?
    /// Tail of the serial commit chain; awaiting it awaits everything before it.
    private var tail: Task<Void, Never>?

    /// Whether the 1 Hz sampler is running. `false` whenever playback is not active —
    /// the observable half of the idle-CPU contract.
    public var isSampling: Bool {
        samplingTask != nil
    }

    /// - Parameters:
    ///   - heat: The v15 heatmap merge target.
    ///   - tracks: Read side for the album/genre a ``TrackRef`` deliberately omits.
    ///   - playhead: The live playback readings to sample.
    ///   - now: Wall clock for the row's `updatedAt`. Injected so tests can pin it.
    public init(
        heat: any PlaySegmentHeatRepositoryProviding,
        tracks: any TrackRepositoryProviding,
        playhead: PlaySegmentPlayhead,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.heat = heat
        self.tracks = tracks
        self.playhead = playhead
        self.now = now
        attributionProfileId = playhead.activeProfileId()
    }

    deinit {
        samplingTask?.cancel()
    }

    public func beginTrack(trackRef: TrackRef, profileId: Int64) {
        attributionProfileId = profileId
        // Anything still open belonged to a pass the coordinator already flushed
        // (it emits the outgoing signal before it starts the incoming track).
        discardOpenState()
        active = Self.makeActive(trackRef, profileId: profileId)
    }

    public func ingest(sample: PlayheadSample) {
        if sample.isPlaying {
            beginLazilyIfNeeded()
        }
        guard active != nil else { return }
        if sample.isPlaying {
            advanceOpenRange(to: sample.time)
        } else {
            completeOpenRange(at: sample.time)
        }
    }

    public func noteSeek(from origin: TimeInterval, to target: TimeInterval) {
        guard active != nil else { return }
        if openStart != nil {
            openEnd = origin
            closeOpenRange()
        }
        openRange(at: target)
    }

    public func playbackStateDidChange(isPlaying: Bool) {
        guard isPlaying != isSampling else { return }
        if isPlaying {
            // Before the first delayed tick, so a track shorter than one interval
            // still records where it started.
            ingest(sample: PlayheadSample(time: playhead.currentTime(), isPlaying: true))
            startSampling()
        } else {
            // Before cancelling: this final reading is what closes the open listen.
            ingest(sample: PlayheadSample(time: playhead.currentTime(), isPlaying: false))
            stopSampling()
        }
    }

    public func flush(signal: PlayEventSignal) {
        extendForNaturalEnd(signal)
        closeOpenRange()
        let snapshot = active
        let ranges = pending
        active = nil
        discardOpenState()
        commit(ranges, for: snapshot)
    }

    public func rescope(to profileId: Int64) {
        attributionProfileId = profileId
    }

    public func flushAndWait() async {
        await tail?.value
    }
}

// MARK: - Listen accrual

private extension PlaySegmentTracker {
    /// Adopts whatever is playing, for the paths that never fire `onTrackStarted`.
    ///
    /// Launch restore, a `play()` resume of a restored queue, and every manual-queue
    /// play reach the engine without an `onTrackStarted`, so `beginTrack` would never
    /// run for them. The first playing tick with nothing open therefore begins the
    /// track itself, from exactly the same inputs.
    func beginLazilyIfNeeded() {
        guard active == nil, let track = playhead.currentTrack() else { return }
        active = Self.makeActive(track, profileId: attributionProfileId)
    }

    static func makeActive(_ track: TrackRef, profileId: Int64) -> ActiveTrack? {
        guard let trackId = track.trackID, let duration = track.duration, duration > 0 else { return nil }
        return ActiveTrack(
            trackId: trackId,
            profileId: profileId,
            identity: PlaySegmentIdentity(
                artistName: track.artist,
                title: track.title,
                durationSeconds: duration
            )
        )
    }

    func advanceOpenRange(to time: TimeInterval) {
        guard let end = openEnd else {
            openRange(at: time)
            return
        }
        let step = time - end
        if step >= Self.minimumStep, step <= Self.maximumStep {
            openEnd = time
        } else {
            closeOpenRange()
            openRange(at: time)
        }
    }

    /// The playback-stopped path: extend by the final partial step if it is
    /// contiguous, then close. Never opens a new listen — nothing is playing.
    func completeOpenRange(at time: TimeInterval) {
        if let end = openEnd {
            let step = time - end
            if step >= Self.minimumStep, step <= Self.maximumStep {
                openEnd = time
            }
        }
        closeOpenRange()
    }

    func openRange(at time: TimeInterval) {
        openStart = time
        openEnd = time
    }

    /// Moves the open listen into `pending`. A degenerate range is appended as-is and
    /// filtered later, so the drop rule lives in exactly one place
    /// (``PlaySegmentBuckets/minimumCommittedLength``).
    func closeOpenRange() {
        defer {
            openStart = nil
            openEnd = nil
        }
        guard let start = openStart, let end = openEnd else { return }
        pending.append(PlaySegmentRange(start: start, end: end))
    }

    func discardOpenState() {
        pending = []
        openStart = nil
        openEnd = nil
    }

    /// Completes the open listen to the full duration when the track really did run
    /// out — and only then.
    ///
    /// The last 1 Hz tick lands up to a second before the end, so without this a
    /// natural end would leave the final bucket empty. The tolerance is what keeps it
    /// honest: a range opened at a gapless successor's ~0 s position is nowhere near
    /// the outgoing track's duration, so it is left to die as a zero-length range.
    func extendForNaturalEnd(_ signal: PlayEventSignal) {
        guard signal.reason == .natural,
              let end = openEnd,
              let duration = active?.identity.durationSeconds,
              duration > 0,
              abs(duration - end) <= Self.naturalExtendTolerance
        else { return }
        openEnd = duration
    }
}

// MARK: - Sampling

private extension PlaySegmentTracker {
    /// A 1 Hz main-actor loop that exists only while playing.
    ///
    /// Each tick reads the engine's `currentTime` property — a cheap main-actor read,
    /// never a render-thread touch.
    func startSampling() {
        guard samplingTask == nil else { return }
        let interval = Self.sampleInterval
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                ingest(sample: PlayheadSample(time: playhead.currentTime(), isPlaying: true))
            }
        }
    }

    func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
    }
}

// MARK: - Commit

private extension PlaySegmentTracker {
    /// Writes one pass, off the main actor.
    ///
    /// The two guard rails are already enforced by ``makeActive(_:profileId:)`` — a
    /// snapshot only exists for a library track of known length — so all that is left
    /// is to skip a pass that listened to nothing at all.
    func commit(_ ranges: [PlaySegmentRange], for snapshot: ActiveTrack?) {
        guard let snapshot else { return }
        let deltas = PlaySegmentBuckets.deltas(for: ranges, duration: snapshot.identity.durationSeconds)
        guard deltas.contains(where: { $0 > 0 }) else { return }
        let heat = heat
        let tracks = tracks
        let updatedAt = now()
        enqueue {
            let identity = await Self.resolvingIdentity(snapshot.identity, trackId: snapshot.trackId, in: tracks)
            try? await heat.mergeSegmentHeat(
                profileId: snapshot.profileId,
                trackId: snapshot.trackId,
                identity: identity,
                deltas: deltas,
                updatedAt: updatedAt
            )
        }
    }

    /// Chains `work` behind everything already enqueued.
    ///
    /// Serial by construction, so passes land in listening order and
    /// ``flushAndWait()`` only has to await the tail. Detached because the work hits
    /// the database and must never run on the main actor.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task.detached(priority: .utility) {
            await previous?.value
            await work()
        }
    }

    /// Fills in the two fields ``TrackRef`` deliberately does not carry.
    ///
    /// `TrackRef` stays DB-free so the playback hot path never touches SQLite; album
    /// and genre are therefore read here, once, off-main. When the track row is
    /// already gone the ref-derived identity is kept as-is and the merge preserves
    /// whatever the row last knew.
    nonisolated static func resolvingIdentity(
        _ identity: PlaySegmentIdentity,
        trackId: Int64,
        in tracks: any TrackRepositoryProviding
    ) async -> PlaySegmentIdentity {
        let stored = await Task.detached(priority: .utility) {
            try? tracks.fetchTrack(id: trackId)
        }.value
        guard let stored else { return identity }
        var resolved = identity
        resolved.albumTitle = stored.albumTitle
        resolved.genre = stored.genre
        resolved.artistName = identity.artistName ?? stored.artistName
        resolved.title = identity.title ?? stored.title
        return resolved
    }
}
