// Shared doubles for the play-event suites.
//
// The engine double is the same `SpyPlaybackEngine` the rest of the coordinator
// suite uses; its inner `FakePlaybackEngine` already zeroes `currentTime` on
// `stop()`, which is exactly what production does and what makes the
// stop-then-play edge observable in tests.
import AudioEngine
import Foundation
@testable import Services
import Testing

@MainActor
final class PlayEventSpy {
    private(set) var signals: [PlayEventSignal] = []

    func record(_ signal: PlayEventSignal) {
        signals.append(signal)
    }

    var reasons: [PlayEndReason] {
        signals.map(\.reason)
    }

    var surfaces: [String] {
        signals.map(\.sourceSurface)
    }
}

struct SeekRecord: Equatable {
    let from: TimeInterval
    let target: TimeInterval
}

@MainActor
final class SeekSpy {
    private(set) var seeks: [SeekRecord] = []

    func record(from: TimeInterval, to target: TimeInterval) {
        seeks.append(SeekRecord(from: from, target: target))
    }
}

/// A coordinator wired to a spy engine and a frozen clock.
///
/// The clock is frozen so `startedAt` can only be correct by having been stamped
/// at the play's begin — the fallback (`now − elapsed`) yields a different value
/// for any non-zero elapsed, so the two are always distinguishable.
@MainActor
struct PlayEventHarness {
    static let epoch: Double = 1_700_000_000
    static let trackDuration: Double = 100
    static let failingExtension = "bad"

    let coordinator: PlaybackCoordinator
    let engine: SpyPlaybackEngine
    let events = PlayEventSpy()
    let seeks = SeekSpy()

    init(duration: Double = PlayEventHarness.trackDuration, allowFailingLoads: Bool = false) {
        let provider = FakeDecoderProvider(
            duration: duration,
            corruptExtensions: allowFailingLoads ? [Self.failingExtension] : []
        )
        engine = SpyPlaybackEngine(decoderProvider: provider)
        coordinator = PlaybackCoordinator(
            engine: engine,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 0)
        )
        coordinator.nowProvider = { PlayEventHarness.epoch }
        let events = events
        let seeks = seeks
        coordinator.onPlayEvent = { events.record($0) }
        coordinator.onSeek = { seeks.record(from: $0, to: $1) }
    }

    /// A ref whose backing "file" the fake decoder refuses to open.
    static func failingTrack(_ name: String) -> TrackRef {
        TrackRef(filePath: "/fixtures/\(name).\(failingExtension)", title: name)
    }

    static func track(_ name: String, id trackID: Int64) -> TrackRef {
        TrackRef(
            trackID: trackID,
            filePath: "/fixtures/\(name).fake",
            title: name,
            artist: "artist-\(name)"
        )
    }
}
