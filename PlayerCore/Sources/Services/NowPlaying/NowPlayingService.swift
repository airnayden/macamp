//
//  NowPlayingService.swift
//  Services
//
//  Keeps `MPNowPlayingInfoCenter` in sync with the current track and playback
//  status, and mirrors a tiny now-playing snapshot for the widget / App Group.
//

import Foundation
import MediaPlayer
import Models

/// Builds and publishes the system "now playing" information.
///
/// The service is *push based*: the application layer observes the playback
/// coordinator and feeds metadata / playback updates in. This keeps the service
/// free of any direct engine or coordinator dependency and makes it trivially
/// testable.
///
/// Elapsed time is **not** pushed every frame. We set the elapsed time together
/// with the playback `rate` so the system extrapolates the current position on
/// its own; callers only need to push on state changes (play / pause / seek /
/// track) plus an occasional periodic position sync.
public final class NowPlayingService: NowPlayingControlling {
    private let infoCenter: NowPlayingInfoCentering
    private let snapshotWriter: SnapshotWriting?
    private let artworkProvider: NowPlayingArtworkFactory?

    private var metadata: NowPlayingMetadata?
    private var status: PlaybackStatus = .stopped

    public init(
        infoCenter: NowPlayingInfoCentering = MPNowPlayingInfoCenter.default(),
        snapshotWriter: SnapshotWriting? = nil,
        artworkProvider: NowPlayingArtworkFactory? = nil
    ) {
        self.infoCenter = infoCenter
        self.snapshotWriter = snapshotWriter
        self.artworkProvider = artworkProvider
    }

    // MARK: - NowPlayingControlling

    public func updateTrack(_ metadata: NowPlayingMetadata?) {
        self.metadata = metadata
        if metadata == nil {
            status = .stopped
        }
        publish()
    }

    public func updatePlayback(_ status: PlaybackStatus) {
        self.status = status
        publish()
    }

    public func syncPosition(elapsed: TimeInterval) {
        status.elapsed = elapsed
        publish()
    }

    public func clear() {
        metadata = nil
        status = .stopped
        infoCenter.nowPlayingInfo = nil
        writeSnapshot()
    }

    // MARK: - Info construction

    /// Builds the dictionary published to `MPNowPlayingInfoCenter`.
    ///
    /// Exposed so tests can assert the exact payload without a real info center.
    public func makeNowPlayingInfo() -> [String: Any] {
        guard let metadata else { return [:] }

        // Native values (MediaPlayer bridges Double -> NSNumber for the system).
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPMediaItemPropertyPlaybackDuration: metadata.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: status.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: status.rate,
        ]

        if let artist = metadata.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = metadata.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork = artworkProvider?(metadata) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }

    // MARK: - Snapshot

    /// Builds the widget snapshot (deliberately tiny — never the live DB).
    public func makeSnapshot() -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: metadata?.title ?? "",
            artist: metadata?.artist,
            album: metadata?.album,
            artworkRef: metadata?.artworkRef,
            duration: metadata?.duration ?? 0,
            elapsed: status.elapsed,
            isPlaying: status.isPlaying
        )
    }

    // MARK: - Private

    private func publish() {
        infoCenter.nowPlayingInfo = makeNowPlayingInfo()
        infoCenter.playbackState = status.isPlaying ? .playing : (metadata != nil ? .paused : .stopped)
        writeSnapshot()
    }

    private func writeSnapshot() {
        guard let snapshotWriter else { return }
        try? snapshotWriter.write(makeSnapshot())
    }
}
