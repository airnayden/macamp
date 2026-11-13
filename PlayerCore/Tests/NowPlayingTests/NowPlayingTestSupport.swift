import Foundation
import MediaPlayer
import Models
@testable import Services

final class FakeNowPlayingInfoCenter: NowPlayingInfoCentering {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .unknown
}

final class FakeSnapshotWriter: SnapshotWriting {
    private(set) var written: [NowPlayingSnapshot] = []

    var latest: NowPlayingSnapshot? {
        written.last
    }

    func write(_ snapshot: NowPlayingSnapshot) throws {
        written.append(snapshot)
    }
}

final class FakeNowPlayingController: NowPlayingControlling {
    private(set) var tracks: [NowPlayingMetadata?] = []
    private(set) var statuses: [PlaybackStatus] = []
    private(set) var positions: [TimeInterval] = []
    private(set) var clearCount = 0

    func updateTrack(_ metadata: NowPlayingMetadata?) {
        tracks.append(metadata)
    }

    func updatePlayback(_ status: PlaybackStatus) {
        statuses.append(status)
    }

    func syncPosition(elapsed: TimeInterval) {
        positions.append(elapsed)
    }

    func clear() {
        clearCount += 1
    }
}

@MainActor
final class SpyCoordinator: PlaybackCoordinating {
    enum Command: Equatable {
        case play
        case pause
        case toggle
        case stop
        case next
        case previous
        case seek(TimeInterval)
        case playAt(Int)
    }

    private(set) var commands: [Command] = []

    var state = CoordinatorState()
    var stateDidChange: ((CoordinatorState) -> Void)?
    var current: TrackRef?
    var queue: [TrackRef] = []
    var history: [TrackRef] = []
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 1.0
    func setVolume(_: Float) {}
    var balance: Float = 0
    func setBalance(_: Float) {}
    var manualQueue: [TrackRef] = []
    var karaokeActive = false
    func setKaraokeActive(_ active: Bool) {
        karaokeActive = active
    }

    func toggleKaraoke() {
        karaokeActive.toggle()
    }

    func play() {
        commands.append(.play)
    }

    func pause() {
        commands.append(.pause)
    }

    func togglePlayPause() {
        commands.append(.toggle)
    }

    func stop() {
        commands.append(.stop)
    }

    func next() {
        commands.append(.next)
    }

    func previous() {
        commands.append(.previous)
    }

    func seek(to time: TimeInterval) {
        commands.append(.seek(time))
    }

    func play(at index: Int) {
        commands.append(.playAt(index))
    }

    func setQueue(_: [TrackRef], startingAt _: Int?) {}
    func setQueue(_: [TrackRef], startingAt _: Int, engagingKaraoke _: Bool, source _: PlaybackSource?) {}
    func append(_: TrackRef) {}
    func append(contentsOf _: [TrackRef]) {}
    func insert(_: TrackRef, at _: Int) {}
    func remove(at _: Int) {}
    func move(from _: Int, to _: Int) {}
    func removeAll() {}
    func reorderQueue(_: [TrackRef]) {}
    func enqueueManual(_: TrackRef) {}
    func enqueueManual(contentsOf _: [TrackRef]) {}
    func playNextManual(contentsOf _: [TrackRef]) {}
    func removeManual(at _: Int) {}
    func moveManual(from _: Int, to _: Int) {}
    func playManual(at _: Int) {}
    func clearManualQueue() {}

    func prescheduleNextIfNeeded() {}
    func handleTrackDidFinish() {}

    func snapshot() -> CoordinatorSnapshot {
        CoordinatorSnapshot(
            entries: [],
            order: [],
            currentID: nil,
            shuffle: false,
            repeatMode: .off,
            position: 0
        )
    }

    func restore(from _: CoordinatorSnapshot) {}
}
