// PlaybackControlWitness — the composition root's conformer of
// ``ToolboxPlaybackControlling`` over the REAL `PlaybackCoordinator`.
//
// The exact shape `LibraryChatProposalFiler` established for the proposal seam,
// applied to the player: a `@MainActor` class (therefore implicitly `Sendable`)
// witnessing `async` protocol requirements, living in the shell because
// `Services/Toolbox/` must not name a coordinator, a repository row, or a file
// path.
//
// ── IT RESOLVES IDS A SECOND TIME, AND THAT IS THE POINT ─────────────────────
//
// The tool has already validated every id against the active profile's VISIBLE
// library and told the model which ones it accepted. This resolves them again —
// to `TrackRef`s, which carry `filePath`, which is exactly why the toolbox could
// not do it. One indexed batch read of at most 100 rows buys the invariant that
// no file path exists anywhere under `Toolbox/`. See `ToolboxPlaybackSeam.swift`.
//
// An id that fails to resolve here is DROPPED rather than reported: the tool's
// answer has already been composed, and a second, later refusal would contradict
// a sentence the model has been given.
//
// ── WHAT "UP NEXT" CAN HONESTLY BE ───────────────────────────────────────────
//
// `PlaybackCoordinating` publishes the queue in ENTRY order and the play order
// only indirectly, through `history` (which is `order[0..<position]`). With
// shuffle OFF the two coincide and the upcoming entries are listed. With shuffle
// ON the entry order is NOT the play order, so this reports the manual queue —
// which genuinely does play next, by the coordinator's own precedence rule — and
// the correct REMAINING COUNT derived from `history.count`, but names no context
// tracks it cannot put in the right order. `ToolboxPlaybackSnapshot.upNextTotal`
// is `>= upNext.count` for precisely this case, and the state sentence states the
// total in words. Listing entry order under shuffle would be a confident wrong
// answer; this is a smaller true one.
import AudioEngine
import Foundation
import Persistence
import Services

@MainActor
final class PlaybackControlWitness: ToolboxPlaybackControlling {
    private let coordinator: any PlaybackCoordinating
    private let tracks: TrackRepository
    private let profileId: @MainActor () -> Int64

    init(
        coordinator: any PlaybackCoordinating,
        tracks: TrackRepository,
        profileId: @escaping @MainActor () -> Int64
    ) {
        self.coordinator = coordinator
        self.tracks = tracks
        self.profileId = profileId
    }

    /// The witness over a live environment's player and library.
    ///
    /// Here rather than at the property in `AppEnvironment.swift`, whose 400-line
    /// budget is the tightest in the shell — and because the profile is read
    /// LAZILY through a closure, which is the one wiring detail worth stating
    /// beside the type that depends on it: a profile switch rebuilds the toolbox
    /// but not this object, so a captured id would go stale.
    static func over(_ environment: AppEnvironment) -> PlaybackControlWitness {
        PlaybackControlWitness(
            coordinator: environment.coordinator,
            tracks: TrackRepository(environment.database),
            profileId: { [weak environment] in
                environment?.profileService.activeProfile.id ?? ProfileRecord.guestID
            }
        )
    }

    func playbackSnapshot(upNextLimit: Int) async -> ToolboxPlaybackSnapshot {
        snapshot(upNextLimit: upNextLimit)
    }

    func playTracks(ids: [Int64]) async -> ToolboxPlaybackSnapshot {
        let refs = await resolve(ids)
        guard !refs.isEmpty else { return snapshot() }
        coordinator.setQueue(refs, startingAt: 0)
        return snapshot()
    }

    func queueTracks(ids: [Int64], position: ToolboxQueuePosition) async -> ToolboxPlaybackSnapshot {
        let refs = await resolve(ids)
        guard !refs.isEmpty else { return snapshot() }
        switch position {
        case .next: coordinator.playNextManual(contentsOf: refs)
        case .last: coordinator.enqueueManual(contentsOf: refs)
        }
        return snapshot()
    }

    func perform(_ action: ToolboxTransportAction) async -> ToolboxPlaybackSnapshot {
        switch action {
        case .play: coordinator.play()
        case .pause: coordinator.pause()
        case .next: coordinator.next()
        case .previous: coordinator.previous()
        case .stop: coordinator.stop()
        }
        return snapshot()
    }
}

// MARK: - Resolution

private extension PlaybackControlWitness {
    /// The caller's ids as queue entries, IN THE ORDER ASKED FOR.
    ///
    /// `resolvedTracks` answers a dictionary, so the order is rebuilt by walking
    /// the caller's list — the same discipline `get_tracks` uses, and the reason
    /// "play these three in this order" means what it says.
    func resolve(_ ids: [Int64]) async -> [TrackRef] {
        let profile = profileId()
        guard let resolved = try? await tracks.resolvedTracks(profileId: profile, trackIds: ids) else {
            return []
        }
        return ids.compactMap { resolved[$0].map { TrackRef(record: $0.track) } }
    }
}

// MARK: - Reading the player

private extension PlaybackControlWitness {
    func snapshot(upNextLimit: Int = ToolResultBudget.playbackQueuePreviewLimit) -> ToolboxPlaybackSnapshot {
        let state = coordinator.state
        let upcoming = upcoming(state)
        return ToolboxPlaybackSnapshot(
            activity: Self.activity(state.playback),
            current: state.current.map(Self.entry),
            elapsedSeconds: coordinator.currentTime,
            durationSeconds: coordinator.duration,
            isShuffling: state.shuffle,
            repeatSetting: Self.setting(state.repeatMode),
            upNext: upcoming.named.prefix(max(0, upNextLimit)).map(Self.entry),
            upNextTotal: upcoming.total
        )
    }

    /// The entries that can be NAMED, and how many there really are. See the file
    /// header for why those are two different numbers under shuffle.
    func upcoming(_ state: CoordinatorState) -> (named: [TrackRef], total: Int) {
        let manual = state.manualQueue
        guard let current = state.current else { return (manual, manual.count) }
        guard !state.shuffle else {
            let remaining = max(0, state.queue.count - state.history.count - 1)
            return (manual, manual.count + remaining)
        }
        guard let index = state.queue.firstIndex(where: { $0.id == current.id }) else {
            // The current track came from the MANUAL queue, so it is not in the
            // context queue at all and none of it has been consumed.
            return (manual + state.queue, manual.count + state.queue.count)
        }
        let remaining = Array(state.queue[state.queue.index(after: index)...])
        return (manual + remaining, manual.count + remaining.count)
    }

    static func entry(_ ref: TrackRef) -> ToolboxPlaybackEntry {
        ToolboxPlaybackEntry(
            trackId: ref.trackID,
            title: ref.title,
            artist: ref.artist,
            durationSeconds: ref.duration
        )
    }

    /// `PlaybackState.idle` is "stopped with nothing loaded", a distinction the
    /// player needs and a model does not — so it folds into `.stopped`.
    static func activity(_ state: PlaybackState) -> ToolboxPlaybackActivity {
        switch state {
        case .playing: .playing
        case .paused: .paused
        case .stopped, .idle: .stopped
        }
    }

    static func setting(_ mode: RepeatMode) -> ToolboxRepeatSetting {
        switch mode {
        case .off: .off
        case .one: .one
        case .all: .all
        }
    }
}
