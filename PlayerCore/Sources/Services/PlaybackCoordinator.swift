// PlaybackCoordinator — the concrete now-playing coordinator.
//
// The coordinator is a thin orchestrator: a pure ``PlaybackQueue`` value owns the
// queue, stable shuffle order, availability skipping and history, while this
// class translates the queue's decisions into ``PlaybackEngine`` calls and mirrors
// the engine's transport state into an observable ``CoordinatorState``. The queue
// decides WHAT plays; the engine RENDERS it; the two never overlap.
//
// Crossfade is NOT implemented (ADR Option A — deferred). Disk is never touched
// on the hot path: the queue holds already-resolved ``TrackRef`` values.
//
// This file imports only AudioEngine + Foundation + Persistence + Separation; it
// MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import AudioEngine
import Foundation
import Persistence
import Separation

/// The production ``PlaybackCoordinating`` over an injected ``PlaybackEngine``.
@MainActor
public final class PlaybackCoordinator: PlaybackCoordinating {
    public internal(set) var state = CoordinatorState() {
        didSet {
            if state != oldValue {
                stateDidChange?(state)
            }
        }
    }

    public var stateDidChange: ((CoordinatorState) -> Void)?
    /// Publishes queue-source metadata before a replacement queue emits state.
    public var playbackSourceDidChange: ((PlaybackSource?) -> Void)?
    /// Fired exactly once per real playback transition, describing the OUTGOING
    /// play (see ``PlaybackCoordinator+PlayEvent.swift``).
    public var onPlayEvent: ((PlayEventSignal) -> Void)?
    /// Fired on every user seek with `(from, to)` in seconds. This is a position
    /// change, NOT a transition: it never emits a ``PlayEventSignal``.
    public var onSeek: ((TimeInterval, TimeInterval) -> Void)?
    /// Awaited immediately BEFORE ``PlaybackEngine/load(_:)`` on the two
    /// EXPLICIT-START paths — ``activate(requestedID:startPlaying:)`` and
    /// ``activateManual(_:startPlaying:)`` — and on NO other path. It is
    /// deliberately absent from ``prescheduleNextIfNeeded()`` and
    /// ``restore(from:)``: preparing the output route mid-render glitches the
    /// stream still playing, and a restore is not a track start.
    ///
    /// `@Sendable`, so the hook runs off the main actor; a conformer MUST bound
    /// its own wait, because an unbounded one stalls activation forever. `nil` —
    /// the shipped default and every non-macOS shell — keeps activation fully
    /// synchronous.
    public var preLoadHook: (@Sendable (TrackRef) async -> Void)?

    // `internal` (not `private`) so the orchestration extension can live in
    // `PlaybackCoordinator+Orchestration.swift` (file-length budget).
    let engine: any PlaybackEngine
    var rng: any RandomNumberGenerator
    var plan = PlaybackQueue()
    var repeatModeValue: RepeatMode = .off

    /// User-enqueued tracks consumed (front-first) before the context queue
    /// resumes. Separate from `plan` so double-clicking a folder/playlist plays
    /// in context without polluting this list.
    var manualQueueEntries: [TrackRef] = []
    /// The manual-queue track currently rendering, if any. While set, ``current``
    /// reports it rather than `plan.current` (which stays at the context track).
    var currentManualTrack: TrackRef?

    /// The id most recently handed to ``PlaybackEngine/enqueue(_:)``; guards
    /// against enqueuing the same successor twice within one track.
    var lastScheduledNextID: UUID?

    /// Bumped by every activation and every terminal teardown. A ``preLoadHook``
    /// continuation whose captured token no longer matches has been superseded —
    /// by a newer activation, a `stop()` or a queue clear — and must not load.
    var preLoadGeneration = 0

    // MARK: Karaoke source resolution (see PlaybackCoordinator+Karaoke.swift)

    let instrumentalCache: (any InstrumentalCaching)?
    let karaokeModelSHA: String
    var karaokeSeparatorAvailable: Bool
    public internal(set) var karaokeActive = false
    var desiredKaraokeActive = false
    /// Pre-resolved instrumental URLs keyed by the ORIGINAL row's v20
    /// ``TrackRecord/Identity``, populated asynchronously so the sync
    /// ``playbackSource(for:)`` seam never awaits the cache. Keyed by identity rather
    /// than by path because a `.cue` sheet makes one audio file back N rows.
    var resolvedInstrumentals: [TrackRecord.Identity: URL] = [:]
    /// What the engine was last handed, so a karaoke toggle can skip a reload that
    /// would change nothing. Compares the whole ``DecoderSource``: two cue segments
    /// of one disc image are URL-equal and differ only in their frame range.
    var activePlaybackSource: DecoderSource?
    var pinnedInstrumentalKeys: Set<SeparationCacheKey> = []
    var karaokeDebounceInterval: Duration = .milliseconds(300)
    var karaokeDebounceTask: Task<Void, Never>?
    var karaokeWarmTask: Task<Void, Never>?
    var karaokeRestoreTask: Task<Void, Never>?
    /// Fired when karaoke auto-deactivates on an unresolved current track
    /// (activation-miss or an advance onto an uncached track) so the shell can
    /// toast. The restore path corrects state silently and does NOT fire this.
    public var onKaraokeAutoDeactivated: (() -> Void)?

    public var onTrackPlayed: ((Int64) -> Void)?
    public var onTrackStarted: ((Int64) -> Void)?
    var listenTimerTask: Task<Void, Never>?
    var currentListenTrackID: Int64?
    public var onTrackListened: ((Int64) -> Void)?
    /// Play time before a track counts as "listened"; injectable so tests drive
    /// the ``onTrackListened`` timer without a real 60-second wait.
    var listenThreshold: Duration = .seconds(60)

    // MARK: Play-event instrumentation (see PlaybackCoordinator+PlayEvent.swift)

    /// Guards ``emitOutgoingPlayEvent(reason:)`` so nested transport paths emit
    /// exactly one event per transition.
    var transitionConsumed = false
    /// Epoch seconds at which the loaded item first started playing; `nil` until
    /// it does (a load-while-paused or a restored-but-not-resumed session).
    var currentBeganAt: Double?
    /// The loaded item's duration, captured at load time because a gapless engine
    /// may already report the successor's by the time the play ends.
    var currentTrackDuration: Double = 0
    /// The surface the current context queue came from, owned here rather than in
    /// the shell so an emitted event can name it after the queue has moved on.
    var activeSource: PlaybackSource?
    /// Wall-clock seconds since the Unix epoch; injectable for deterministic tests.
    var nowProvider: () -> Double = { Date().timeIntervalSince1970 }

    /// Creates a coordinator driving `engine`.
    ///
    /// - Parameters:
    ///   - engine: The transport this coordinator orchestrates.
    ///   - randomNumberGenerator: Shuffle randomness (seedable in tests).
    public init(
        engine: any PlaybackEngine,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator(),
        instrumentalCache: (any InstrumentalCaching)? = nil,
        karaokeModelSHA: String = "",
        karaokeSeparatorAvailable: Bool = false
    ) {
        self.engine = engine
        rng = randomNumberGenerator
        self.instrumentalCache = instrumentalCache
        self.karaokeModelSHA = karaokeModelSHA
        self.karaokeSeparatorAvailable = karaokeSeparatorAvailable
        engine.stateDidChange = { [weak self] engineState in
            if engineState == .playing { self?.markPlaybackBegan() }
            self?.publish()
        }
        engine.onEndOfAudio = { [weak self] in
            self?.handleTrackDidFinish()
        }
        engine.onRenderingComplete = { [weak self] in
            self?.prescheduleNextIfNeeded()
        }
    }

    // MARK: Derived accessors

    public var current: TrackRef? {
        currentManualTrack ?? plan.current
    }

    public var queue: [TrackRef] {
        plan.entries
    }

    public var manualQueue: [TrackRef] {
        manualQueueEntries
    }

    public var history: [TrackRef] {
        plan.history
    }

    public var currentTime: TimeInterval {
        engine.currentTime
    }

    public var duration: TimeInterval {
        engine.duration
    }

    public var volume: Float {
        engine.volume
    }

    public func setVolume(_ newVolume: Float) {
        engine.setVolume(newVolume)
    }

    public var balance: Float {
        engine.balance
    }

    public func setBalance(_ newBalance: Float) {
        engine.setBalance(newBalance)
    }

    /// The play order by id — exposed internally for test introspection.
    var order: [UUID] {
        plan.order
    }

    public var shuffle: Bool {
        get { plan.shuffle }
        set {
            plan.setShuffle(newValue, using: &rng)
            publish()
        }
    }

    public var repeatMode: RepeatMode {
        get { repeatModeValue }
        set {
            guard newValue != repeatModeValue else { return }
            repeatModeValue = newValue
            publish()
        }
    }
}

// MARK: - Transport

public extension PlaybackCoordinator {
    func play() {
        if let current = plan.currentID, plan.track(current)?.isPlayable == true {
            engine.play()
            publish()
        } else {
            activate(requestedID: plan.currentID, startPlaying: true)
        }
    }

    func pause() {
        engine.pause()
        publish()
    }

    func togglePlayPause() {
        if engine.state == .playing {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        cancelListenTimer()
        emitOutgoingPlayEvent(reason: .stopped)
        engine.stop()
        finishTerminalTeardown()
        publish()
    }

    func next() {
        advance(.forward, automatic: false)
    }

    func previous() {
        advance(.backward, automatic: false)
    }

    func seek(to time: TimeInterval) {
        let from = engine.currentTime
        let target = segmentClampedSeekTime(time)
        engine.seek(to: target)
        onSeek?(from, target)
    }

    func play(at index: Int) {
        guard plan.entries.indices.contains(index) else { return }
        activate(requestedID: plan.entries[index].id, startPlaying: true)
    }
}

// MARK: - Queue editing

public extension PlaybackCoordinator {
    func setQueue(_ tracks: [TrackRef], startingAt index: Int?) {
        replaceQueue(tracks, startingAt: index, source: nil)
    }

    func append(_ track: TrackRef) {
        plan.append(track)
        applyQueueEdit()
    }

    func append(contentsOf tracks: [TrackRef]) {
        plan.append(contentsOf: tracks)
        applyQueueEdit()
    }

    func insert(_ track: TrackRef, at index: Int) {
        plan.insert(track, at: index)
        applyQueueEdit()
    }

    func remove(at index: Int) {
        guard plan.entries.indices.contains(index) else { return }
        let removedID = plan.entries[index].id
        let wasCurrent = removedID == plan.currentID
        let keepPlaying = engine.state == .playing
        let successor = wasCurrent
            ? plan.nextPlayableID(from: plan.currentID, direction: .forward, repeatMode: repeatModeValue)
            : nil
        if wasCurrent {
            let hasSuccessor = successor != nil && successor != removedID
            emitOutgoingPlayEvent(reason: hasSuccessor ? .jump : .stopped)
        }
        plan.remove(at: index)
        lastScheduledNextID = nil
        guard wasCurrent else {
            publish()
            return
        }
        if let next = successor, next != removedID {
            activate(requestedID: next, startPlaying: keepPlaying)
        } else {
            plan.currentID = nil
            engine.stop()
            finishTerminalTeardown()
            publish()
        }
    }

    func move(from source: Int, to destination: Int) {
        plan.move(from: source, to: destination)
        applyQueueEdit()
    }

    func removeAll() {
        cancelListenTimer()
        emitOutgoingPlayEvent(reason: .stopped)
        plan.removeAll()
        manualQueueEntries.removeAll()
        currentManualTrack = nil
        lastScheduledNextID = nil
        engine.stop()
        activeSource = nil
        playbackSourceDidChange?(nil)
        finishTerminalTeardown()
        publish()
    }

    func reorderQueue(_ tracks: [TrackRef]) {
        let incoming = Set(tracks.compactMap(\.trackID))
        let existing = Set(plan.entries.compactMap(\.trackID))
        guard !incoming.isEmpty, incoming == existing else { return }
        plan.reorder(to: tracks, using: &rng)
        lastScheduledNextID = nil
        publish()
    }
}

// MARK: - Test doubles

public extension PlaybackCoordinator {
    /// A coordinator wired to a file-free ``FakePlaybackEngine`` for higher-layer
    /// tests (view-models) that exercise queue/transport logic without real audio.
    ///
    /// This is the "reuse FakePlaybackEngine" path called out by the task; it
    /// avoids a parallel fake-coordinator that would duplicate this orchestration.
    ///
    /// - Parameters:
    ///   - decoderProvider: Validates the synthetic `load`/`enqueue` calls.
    ///   - seed: Seeds a deterministic shuffle order.
    static func fake(
        decoderProvider: any DecoderProviding = FakeDecoderProvider(),
        seed: UInt64 = 0
    ) -> PlaybackCoordinator {
        PlaybackCoordinator(
            engine: FakePlaybackEngine(decoderProvider: decoderProvider),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: seed)
        )
    }
}
