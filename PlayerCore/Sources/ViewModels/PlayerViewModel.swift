// PlayerViewModel — the now-playing bridge over a ``PlaybackCoordinating``.
//
// It mirrors the coordinator's observable state (current track, transport,
// shuffle/repeat) into `@Observable` properties via the coordinator's single
// `stateDidChange` callback, exposes transport commands that forward to the
// coordinator, and resolves cover art asynchronously through ``ArtworkProviding``
// (cancelling the in-flight fetch whenever the current track changes).
//
// PlayerViewModel OWNS the coordinator's single `stateDidChange` slot;
// ``QueueViewModel`` deliberately uses `refresh()` instead so the two never
// fight over that one callback.
//
// This file imports only Artwork + Foundation + Observation + Separation +
// Services; it MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Artwork
import Foundation
import Observation
import Separation
import Services

/// Drives + observes the now-playing transport for the player UI.
@MainActor
@Observable
public final class PlayerViewModel {
    /// The current (or last-selected) track.
    public private(set) var currentTrack: TrackRef?
    /// `true` when the engine is actively rendering audio.
    public private(set) var isPlaying = false
    /// Live playback position of the current item, in seconds.
    public private(set) var elapsed: TimeInterval = 0
    /// Duration of the current item, in seconds (0 when unknown).
    public private(set) var duration: TimeInterval = 0
    /// Whether shuffle is engaged.
    public private(set) var shuffle = false
    /// The repeat policy.
    public private(set) var repeatMode: RepeatMode = .off
    /// Resolved cover art for the current track, when available.
    public private(set) var artwork: ArtworkResult?
    /// The player-bar karaoke button's derived state — a pure projection of the
    /// settings gate, separator availability, the current track's pre-warm state,
    /// and the coordinator's applied `karaokeActive`. See ``KaraokeButtonState``.
    public private(set) var karaokeButtonState: KaraokeButtonState = .hidden
    /// The current track's instrumental pre-warm fraction (`0..<1`) while
    /// ``KaraokeButtonState/preparing(_:)``, else `nil`. Read by a progress-ring
    /// leaf view in isolation so it re-renders on progress alone, not on unrelated
    /// player-state ticks (macOS UI-performance rule 3).
    public private(set) var karaokePreparationProgress: Double?

    @ObservationIgnored private let coordinator: any PlaybackCoordinating
    @ObservationIgnored private let artworkProvider: any ArtworkProviding
    @ObservationIgnored private let allowsArtworkNetwork: Bool
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var karaokeSettingEnabled = false
    @ObservationIgnored private var karaokeAvailability: SeparationAvailability = .unavailable(reason: .modelNotBundled)
    @ObservationIgnored private var karaokeCoordinatorActive = false
    @ObservationIgnored private var currentTrackPrewarmFraction: Double?
    @ObservationIgnored private var currentTrackKaraokeReady = false

    /// Fires when a press should render the current track's instrumental on demand
    /// (the button is ``KaraokeButtonState/renderable``). Wired by the composition
    /// root; nil-degrading. Invoked by ``requestKaraokeRender()``.
    @ObservationIgnored public var onRenderRequested: ((TrackRef) -> Void)?

    /// Creates a player view model bound to `coordinator`.
    ///
    /// - Parameters:
    ///   - coordinator: The now-playing source of truth (transport + queue).
    ///   - artworkProvider: Async cover-art resolver.
    ///   - allowsArtworkNetwork: Whether artwork resolution may hit the network.
    public init(
        coordinator: any PlaybackCoordinating,
        artworkProvider: any ArtworkProviding,
        allowsArtworkNetwork: Bool = false
    ) {
        self.coordinator = coordinator
        self.artworkProvider = artworkProvider
        self.allowsArtworkNetwork = allowsArtworkNetwork
        coordinator.stateDidChange = { [weak self] state in
            self?.apply(state)
        }
        apply(coordinator.state)
    }

    deinit {
        artworkTask?.cancel()
    }
}

// MARK: - Transport

public extension PlayerViewModel {
    func play() {
        coordinator.play()
    }

    func pause() {
        coordinator.pause()
    }

    func togglePlayPause() {
        coordinator.togglePlayPause()
    }

    func stop() {
        coordinator.stop()
    }

    func next() {
        coordinator.next()
    }

    func previous() {
        coordinator.previous()
    }

    /// Seeks the current item and refreshes the live position.
    func seek(to time: TimeInterval) {
        coordinator.seek(to: time)
        refreshProgress()
    }

    func setShuffle(_ enabled: Bool) {
        coordinator.shuffle = enabled
    }

    func setRepeatMode(_ mode: RepeatMode) {
        coordinator.repeatMode = mode
    }

    var volume: Float {
        coordinator.volume
    }

    func setVolume(_ newVolume: Float) {
        coordinator.setVolume(newVolume)
    }

    var balance: Float {
        coordinator.balance
    }

    func setBalance(_ newBalance: Float) {
        coordinator.setBalance(newBalance)
    }

    func refreshProgress() {
        elapsed = coordinator.currentTime
        let total = coordinator.duration
        if duration != total { duration = total }
    }
}

// MARK: - State + artwork

private extension PlayerViewModel {
    func apply(_ state: CoordinatorState) {
        let previousID = currentTrack?.id
        currentTrack = state.current
        isPlaying = state.playback == .playing
        shuffle = state.shuffle
        repeatMode = state.repeatMode
        refreshProgress()
        if state.current?.id != previousID {
            reloadArtwork(for: state.current)
            currentTrackPrewarmFraction = nil
            currentTrackKaraokeReady = false
        }
        karaokeCoordinatorActive = state.karaokeActive
        recomputeKaraokeState()
    }

    func reloadArtwork(for track: TrackRef?) {
        artworkTask?.cancel()
        artwork = nil
        guard let track else { return }
        let request = ArtworkRequest(
            albumKey: ArtworkRequest.AlbumKey(artist: track.artist ?? "", album: ""),
            sourceURL: track.url,
            rendition: .full,
            allowsNetwork: allowsArtworkNetwork
        )
        let provider = artworkProvider
        artworkTask = Task { [weak self] in
            let result = try? await provider.artwork(for: request)
            if Task.isCancelled { return }
            self?.artwork = result
        }
    }
}

// MARK: - Karaoke

public extension PlayerViewModel {
    /// Requests a karaoke on/off toggle. Fire-and-forget: it forwards to the
    /// coordinator (which debounces + applies asynchronously) and never awaits.
    func toggleKaraoke() {
        coordinator.toggleKaraoke()
    }

    /// Updates the Settings karaoke gate. `false` ⇒ ``KaraokeButtonState/hidden``.
    func setKaraokeSettingEnabled(_ enabled: Bool) {
        guard karaokeSettingEnabled != enabled else { return }
        karaokeSettingEnabled = enabled
        recomputeKaraokeState()
    }

    /// Updates the resolved separator availability. `.unavailable` ⇒
    /// ``KaraokeButtonState/disabled(reason:)``.
    func setKaraokeAvailability(_ availability: SeparationAvailability) {
        guard karaokeAvailability != availability else { return }
        karaokeAvailability = availability
        recomputeKaraokeState()
    }

    /// Ingests one pre-warm progress event; only the CURRENT track's fraction moves
    /// the button (upcoming-track progress is irrelevant to it). Wire to
    /// `KaraokePrewarmService.onProgress`.
    func ingestKaraokePrewarmProgress(_ progress: KaraokePrewarmProgress) {
        guard progress.url == currentTrack?.url else { return }
        guard currentTrackPrewarmFraction != progress.fraction else { return }
        currentTrackPrewarmFraction = progress.fraction
        recomputeKaraokeState()
    }

    /// Updates whether the current track has a cached instrumental (fed by the
    /// karaoke ready store). Equality-guarded: a redundant set neither recomputes
    /// nor writes any observable state.
    func setCurrentTrackKaraokeReady(_ ready: Bool) {
        guard currentTrackKaraokeReady != ready else { return }
        currentTrackKaraokeReady = ready
        recomputeKaraokeState()
    }

    /// Requests an on-demand instrumental render for the current track via
    /// ``onRenderRequested``. A no-op when there is no current track, or when it is a
    /// cue segment — those are never separable (``SeparationUnavailableReason/cueSegment``),
    /// so the button is already `.disabled` and this guard keeps a programmatic press
    /// from reaching the render queue behind its back.
    func requestKaraokeRender() {
        guard let track = currentTrack, !track.isCueSegment else { return }
        onRenderRequested?(track)
    }
}

extension PlayerViewModel {
    /// Pure projection of the karaoke button's inputs — no live coordinator or
    /// service stack required, so the state-derivation table is unit-testable
    /// directly.
    nonisolated static func deriveKaraokeButtonState(
        settingEnabled: Bool,
        availability: SeparationAvailability,
        coordinatorActive: Bool,
        preparation: KaraokePreparation,
        isCueSegment: Bool = false
    ) -> KaraokeButtonState {
        guard settingEnabled else { return .hidden }
        if coordinatorActive { return .active }
        if case let .unavailable(reason) = availability {
            return .disabled(reason: reason)
        }
        if isCueSegment { return .disabled(reason: .cueSegment) }
        switch preparation {
        case .notPrepared:
            return .renderable
        case .cached:
            return .ready
        case let .preparing(fraction):
            return .preparing(fraction)
        }
    }
}

private extension PlayerViewModel {
    func recomputeKaraokeState() {
        let derived = Self.deriveKaraokeButtonState(
            settingEnabled: karaokeSettingEnabled,
            availability: karaokeAvailability,
            coordinatorActive: karaokeCoordinatorActive,
            preparation: currentPreparation(),
            isCueSegment: currentTrack?.isCueSegment == true
        )
        if karaokeButtonState != derived {
            karaokeButtonState = derived
        }
        let progress: Double? = if case let .preparing(fraction) = derived {
            fraction
        } else {
            nil
        }
        if karaokePreparationProgress != progress {
            karaokePreparationProgress = progress
        }
    }

    func currentPreparation() -> KaraokePreparation {
        if currentTrackKaraokeReady { return .cached }
        guard let fraction = currentTrackPrewarmFraction else { return .notPrepared }
        if fraction >= 1.0 {
            return .cached
        }
        return .preparing(fraction)
    }
}

/// The player-bar karaoke (vocal-removal) button's derived state — a pure
/// projection of the Settings karaoke gate, the separator's
/// ``SeparationAvailability``, the current track's ``KaraokePreparation``, and the
/// coordinator's applied `karaokeActive`.
public enum KaraokeButtonState: Equatable, Sendable {
    /// Karaoke is off in Settings — the button is not shown.
    case hidden
    /// Karaoke is on but the separator cannot run; `reason` explains why.
    case disabled(reason: SeparationUnavailableReason)
    /// The current track's instrumental is rendering; `fraction` is `0..<1`.
    case preparing(Double)
    /// No cached instrumental yet — pressing renders one on demand.
    case renderable
    /// The instrumental is cached and ready — pressing engages karaoke instantly.
    case ready
    /// Karaoke is engaged: the instrumental is playing.
    case active
}

/// How ready the current track's karaoke (instrumental) rendition is — the
/// per-track facet feeding ``KaraokeButtonState``.
///
/// Derived WITHOUT an inline cache query (the coordinator's cache is an `actor`;
/// re-awaiting it on the UI path is forbidden) from the current track's pre-warm
/// ``KaraokePrewarmProgress`` fraction alone, where a completed (`>= 1`) render
/// implies a cache hit.
enum KaraokePreparation: Equatable {
    /// A cached instrumental exists — karaoke engages instantly.
    case cached
    /// The instrumental is rendering in the background; `fraction` is `0..<1`.
    case preparing(Double)
    /// No cached instrumental and nothing in flight (a press renders on demand).
    case notPrepared
}
