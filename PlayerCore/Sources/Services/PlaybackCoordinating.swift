// PlaybackCoordinating — the now-playing source of truth for MacAMP.
//
// The coordinator sits between the library/queue and the ``PlaybackEngine``
// (Task 9): it owns the ordered queue, history, shuffle order and repeat mode,
// drives the engine's transport, and pre-schedules the next track for gapless
// continuation. The engine RENDERS audio; the coordinator ORCHESTRATES which
// audio plays and when — the two responsibilities never overlap.
//
// Observability follows the same hand-rolled pattern the engine chose over the
// `@Observable` macro (which is a compiler-plugin that would force the Xcode
// toolchain onto every consumer): a single ``state`` value whose `didSet` fires
// a ``stateDidChange`` callback. UIs observe that callback; tests assert on the
// `state` snapshot directly.
//
// Crossfade is intentionally absent: the Phase 0 ADR (Spikes/ADR-audio-engine.md,
// "Decision: Option A") deferred it because the pinned SFBAudioEngine 0.12.1 has
// no `SFBAudioPlayerNode`, so a two-stream crossfade is not buildable. v1 is a
// single-stream, gapless-only transport.
//
// This file imports only AudioEngine + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation

/// An immutable snapshot of everything a now-playing UI observes.
///
/// Continuously-changing values (``PlaybackCoordinating/currentTime``) are
/// deliberately excluded so a position tick does not spam ``stateDidChange``;
/// position is read live from the engine and captured only into ``snapshot()``.
public struct CoordinatorState: Sendable, Equatable {
    /// The track being played (or last selected), if any.
    public var current: TrackRef?
    /// The full, user-ordered queue — the list ``add``/``remove``/``move`` edit.
    public var queue: [TrackRef]
    /// Tracks already played earlier in the current play-order cycle.
    public var history: [TrackRef]
    /// Whether playback follows a stable shuffled order.
    public var shuffle: Bool
    /// The repeat policy applied at end-of-track / end-of-queue.
    public var repeatMode: RepeatMode
    /// The engine's coarse transport state, mirrored for the UI.
    public var playback: PlaybackState
    /// The user's manually-enqueued tracks, played before the context queue resumes.
    public var manualQueue: [TrackRef]
    /// Whether karaoke (instrumental) playback is currently engaged. `false` also
    /// covers "requested but unavailable" so the UI can surface a disabled toggle.
    public var karaokeActive: Bool

    public init(
        current: TrackRef? = nil,
        queue: [TrackRef] = [],
        history: [TrackRef] = [],
        shuffle: Bool = false,
        repeatMode: RepeatMode = .off,
        playback: PlaybackState = .idle,
        manualQueue: [TrackRef] = [],
        karaokeActive: Bool = false
    ) {
        self.current = current
        self.queue = queue
        self.history = history
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.playback = playback
        self.manualQueue = manualQueue
        self.karaokeActive = karaokeActive
    }
}

/// A persistable capture of the coordinator for state restoration (Task 30).
///
/// Round-trips the current track, its play position and the entire queue —
/// including the precomputed shuffle order — so a relaunch resumes exactly where
/// the user left off. `order` stores the stable play sequence by ``TrackRef/id``.
public struct CoordinatorSnapshot: Codable, Sendable, Equatable {
    /// The user-ordered queue.
    public var entries: [TrackRef]
    /// The play order as a stable sequence of ``TrackRef/id`` values.
    public var order: [UUID]
    /// The current track's ``TrackRef/id`` (`nil` when nothing is selected).
    public var currentID: UUID?
    /// Whether shuffle was engaged.
    public var shuffle: Bool
    /// The repeat policy.
    public var repeatMode: RepeatMode
    /// The current item's playback position in seconds.
    public var position: TimeInterval
    /// Whether karaoke was engaged. ONLY this boolean persists — queue
    /// ``entries`` keep their ORIGINAL file paths, never an instrumental one.
    public var karaokeActive: Bool

    public init(
        entries: [TrackRef],
        order: [UUID],
        currentID: UUID?,
        shuffle: Bool,
        repeatMode: RepeatMode,
        position: TimeInterval,
        karaokeActive: Bool = false
    ) {
        self.entries = entries
        self.order = order
        self.currentID = currentID
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.position = position
        self.karaokeActive = karaokeActive
    }

    private enum CodingKeys: String, CodingKey {
        case entries, order, currentID, shuffle, repeatMode, position, karaokeActive
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([TrackRef].self, forKey: .entries)
        order = try container.decode([UUID].self, forKey: .order)
        currentID = try container.decodeIfPresent(UUID.self, forKey: .currentID)
        shuffle = try container.decode(Bool.self, forKey: .shuffle)
        repeatMode = try container.decode(RepeatMode.self, forKey: .repeatMode)
        position = try container.decode(TimeInterval.self, forKey: .position)
        // Absent on pre-karaoke snapshots — synthesized Codable would throw
        // `keyNotFound`, so decode defensively and default to disabled.
        karaokeActive = try container.decodeIfPresent(Bool.self, forKey: .karaokeActive) ?? false
    }
}

/// The `@MainActor` now-playing coordinator contract.
///
/// Conformers bridge a queue of ``TrackRef`` values to a ``PlaybackEngine``,
/// exposing transport (play/pause/next/previous/seek), queue editing
/// (add/insert/remove/move), shuffle + repeat policy, and resume-from-state
/// hooks. Every member is main-actor isolated: the UI drives the coordinator and
/// observes ``state`` either directly or through ``stateDidChange``.
@MainActor
public protocol PlaybackCoordinating: AnyObject {
    /// The latest observable snapshot.
    var state: CoordinatorState { get }
    /// Invoked on the main actor whenever ``state`` changes value.
    var stateDidChange: ((CoordinatorState) -> Void)? { get set }

    /// The current track (or last selected), if any.
    var current: TrackRef? { get }
    /// The full, user-ordered queue.
    var queue: [TrackRef] { get }
    /// Tracks already played earlier in the current cycle.
    var history: [TrackRef] { get }
    /// Whether playback follows a stable shuffled order.
    var shuffle: Bool { get set }
    /// The repeat policy applied at end-of-track / end-of-queue.
    var repeatMode: RepeatMode { get set }
    /// The current item's live playback position in seconds.
    var currentTime: TimeInterval { get }
    /// The current item's duration in seconds (0 when unknown / none).
    var duration: TimeInterval { get }
    /// The engine's current output volume (0…1).
    var volume: Float { get }
    /// Sets the engine's output volume (clamped to 0…1).
    func setVolume(_ volume: Float)
    /// The engine's stereo balance (−1 left … 0 center … +1 right).
    var balance: Float { get }
    /// Sets the engine's stereo balance (clamped to −1…1).
    func setBalance(_ balance: Float)
    /// The user's manually-enqueued tracks (distinct from the context ``queue``).
    var manualQueue: [TrackRef] { get }
    /// Whether karaoke (instrumental) playback is currently engaged.
    var karaokeActive: Bool { get }

    /// Requests karaoke on/off. A no-op (surfaced as ``karaokeActive == false``)
    /// when the current track is not present or the separator is unavailable.
    /// Rapid calls within the debounce window coalesce to one engine reload.
    func setKaraokeActive(_ active: Bool)
    /// Flips the requested karaoke state via ``setKaraokeActive(_:)``.
    func toggleKaraoke()

    /// Starts or resumes playback (selecting the first playable track if idle).
    func play()
    /// Suspends playback, retaining position.
    func pause()
    /// Toggles between ``play()`` and ``pause()``.
    func togglePlayPause()
    /// Stops playback and resets the engine position to the start.
    func stop()
    /// Advances to the next playable track (honoring shuffle + repeat).
    func next()
    /// Returns to the previous playable track (no-op at the start of the cycle).
    func previous()
    /// Seeks the current item to `time` seconds.
    func seek(to time: TimeInterval)
    /// Plays the queue entry at `index` (skipping forward if it is unavailable).
    func play(at index: Int)

    /// Replaces the queue, optionally starting playback at `index`.
    func setQueue(_ tracks: [TrackRef], startingAt index: Int?)
    /// Replaces the queue and optionally engages karaoke against the selected
    /// track without exposing the toggle debounce race.
    ///
    /// - Parameter source: The source identity to track for restoration, or `nil`
    ///   when the caller has no source to track. Source publication through
    ///   `playbackSourceDidChange` occurs before the queue-replacement state change.
    func setQueue(
        _ tracks: [TrackRef],
        startingAt index: Int,
        engagingKaraoke: Bool,
        source: PlaybackSource?
    )
    /// Appends a track to the end of the queue.
    func append(_ track: TrackRef)
    /// Appends many tracks to the end of the queue.
    func append(contentsOf tracks: [TrackRef])
    /// Inserts `track` at `index` (clamped into `0 ... queue.count`).
    func insert(_ track: TrackRef, at index: Int)
    /// Removes the queue entry at `index` (advancing if it was current).
    func remove(at index: Int)
    /// Moves a queue entry from `source` to `destination`.
    func move(from source: Int, to destination: Int)
    /// Clears the queue and stops playback.
    func removeAll()
    /// Reorders the context queue to match `tracks` (by track identity) without
    /// interrupting playback; a no-op unless `tracks` is the active queue's set.
    func reorderQueue(_ tracks: [TrackRef])

    /// Appends `track` to the manual queue (played before the context resumes).
    func enqueueManual(_ track: TrackRef)
    /// Appends `tracks` to the manual queue.
    func enqueueManual(contentsOf tracks: [TrackRef])
    /// Inserts `tracks` at the front of the manual queue (play next).
    func playNextManual(contentsOf tracks: [TrackRef])
    /// Removes the manual-queue entry at `index`.
    func removeManual(at index: Int)
    /// Moves a manual-queue entry from `source` to `destination`.
    func moveManual(from source: Int, to destination: Int)
    /// Plays the manual-queue entry at `index` now, dropping the ones before it.
    func playManual(at index: Int)
    /// Clears the manual queue.
    func clearManualQueue()

    /// Pre-schedules the next playable track on the engine for gapless playback.
    ///
    /// Called when the engine signals the current item is near-consumed. Idempotent
    /// within a track: it enqueues a given successor at most once.
    func prescheduleNextIfNeeded()
    /// Handles end-of-track: auto-advances honoring repeat policy.
    func handleTrackDidFinish()

    /// Captures the coordinator as a persistable ``CoordinatorSnapshot``.
    func snapshot() -> CoordinatorSnapshot
    /// Restores queue, current track and position from a ``CoordinatorSnapshot``.
    func restore(from snapshot: CoordinatorSnapshot)
}
