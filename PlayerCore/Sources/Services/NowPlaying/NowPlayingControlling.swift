//
//  NowPlayingControlling.swift
//  Services
//
//  The now-playing control surface plus its supporting value types and the
//  injectable `MPNowPlayingInfoCenter` seam used by tests.
//

import Foundation
import MediaPlayer

/// Drives the system "now playing" presentation.
///
/// The application observes the ``PlaybackCoordinating`` and pushes updates in:
/// a track change (``updateTrack(_:)``), a transport change
/// (``updatePlayback(_:)``), or an occasional position tick
/// (``syncPosition(elapsed:)``). ``clear()`` tears the presentation down.
public protocol NowPlayingControlling: AnyObject {
    /// Sets (or clears, with `nil`) the currently presented track's metadata.
    func updateTrack(_ metadata: NowPlayingMetadata?)
    /// Updates the transport status (playing/paused, elapsed, rate).
    func updatePlayback(_ status: PlaybackStatus)
    /// Pushes a fresh elapsed position without changing track or transport.
    func syncPosition(elapsed: TimeInterval)
    /// Removes all now-playing information.
    func clear()
}

/// The subset of `MPNowPlayingInfoCenter` the service depends on, so a test can
/// inject a fake and assert the exact dictionary that would be published.
public protocol NowPlayingInfoCentering: AnyObject {
    /// The dictionary the system reads for the now-playing presentation.
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoCentering {}

/// Converts opaque artwork bytes into the platform artwork object
/// (`MPMediaItemArtwork`). Injected by the app layer because building artwork
/// needs `NSImage`/`UIImage`, which `PlayerCore` must never import.
public typealias NowPlayingArtworkFactory = (NowPlayingMetadata) -> Any?

/// The immutable description of the track shown in the now-playing presentation.
public struct NowPlayingMetadata: Sendable, Equatable {
    /// Display title.
    public var title: String
    /// Display artist, if known.
    public var artist: String?
    /// Display album, if known.
    public var album: String?
    /// Track duration in seconds.
    public var duration: TimeInterval
    /// Raw artwork image bytes, handed to a ``NowPlayingArtworkFactory``.
    public var artworkData: Data?
    /// A stable artwork reference (cache key / file path) carried in the widget
    /// snapshot — the widget resolves the image itself, never via the live DB.
    public var artworkRef: String?

    public init(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval = 0,
        artworkData: Data? = nil,
        artworkRef: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkData = artworkData
        self.artworkRef = artworkRef
    }

    /// Builds metadata from a queued ``TrackRef``.
    ///
    /// `TrackRef` carries no album, so ``album`` is left `nil` for the caller to
    /// supply. A missing title falls back to the file name (a non-translatable
    /// token, never user-facing copy).
    public init(track: TrackRef) {
        self.init(
            title: track.title ?? track.url.lastPathComponent,
            artist: track.artist,
            album: nil,
            duration: track.duration ?? 0
        )
    }
}

/// The transport snapshot the now-playing layer needs.
///
/// `rate` is published alongside `elapsed` so the system EXTRAPOLATES the live
/// position itself (0 when paused stops the clock) — which is why callers do not
/// have to push every frame.
public struct PlaybackStatus: Sendable, Equatable {
    /// Whether the transport is actively playing.
    public var isPlaying: Bool
    /// The current playback position in seconds.
    public var elapsed: TimeInterval
    /// The playback rate (1.0 playing, 0.0 paused) used for extrapolation.
    public var rate: Double

    public init(isPlaying: Bool, elapsed: TimeInterval, rate: Double) {
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.rate = rate
    }

    /// A stopped/idle transport at position zero.
    public static let stopped = PlaybackStatus(isPlaying: false, elapsed: 0, rate: 0)

    /// A playing transport at `elapsed` seconds.
    public static func playing(elapsed: TimeInterval, rate: Double = 1.0) -> PlaybackStatus {
        PlaybackStatus(isPlaying: true, elapsed: elapsed, rate: rate)
    }

    /// A paused transport at `elapsed` seconds (rate 0 freezes extrapolation).
    public static func paused(elapsed: TimeInterval) -> PlaybackStatus {
        PlaybackStatus(isPlaying: false, elapsed: elapsed, rate: 0)
    }
}
