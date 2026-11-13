// Test doubles for the coordinator suite.
//
// `FakePlaybackEngine` (AudioEngine) drives a real transport state machine but
// does NOT record which URLs were loaded/enqueued — so to assert gapless
// pre-scheduling ("the NEXT track was enqueued before the current one ended")
// we wrap it in a thin spy that records `load`/`enqueue` calls while delegating
// every behaviour to the genuine fake. Composition (not duplication) keeps the
// state machine identical to production's double.
import AudioEngine
import Foundation
import Persistence
@testable import Services

/// A ``PlaybackEngine`` that records `load`/`enqueue` URLs, delegating all real
/// behaviour to an inner ``FakePlaybackEngine``.
@MainActor
final class SpyPlaybackEngine: PlaybackEngine {
    private let inner: FakePlaybackEngine

    /// URLs passed to ``load(_:)``, in order (only successful loads recorded).
    private(set) var loadedURLs: [URL] = []
    /// URLs passed to ``enqueue(_:)``, in order (only successful enqueues recorded).
    private(set) var enqueuedURLs: [URL] = []
    /// URLs passed to ``reload(url:at:resumePlaying:)``, in order (only successful reloads recorded).
    private(set) var reloadedURLs: [URL] = []

    /// Sources passed to ``load(source:)``, in order — the URL-only calls arrive
    /// here too (as whole-stream sources), so a frame range is assertable.
    private(set) var loadedSources: [DecoderSource] = []
    /// Sources passed to ``enqueue(source:)``, in order.
    private(set) var enqueuedSources: [DecoderSource] = []
    /// Sources passed to ``reload(source:at:resumePlaying:)``, in order.
    private(set) var reloadedSources: [DecoderSource] = []

    init(decoderProvider: any DecoderProviding = FakeDecoderProvider(duration: 1.0)) {
        inner = FakePlaybackEngine(decoderProvider: decoderProvider)
    }

    var state: PlaybackState {
        inner.state
    }

    var currentTime: TimeInterval {
        inner.currentTime
    }

    var duration: TimeInterval {
        inner.duration
    }

    var stateDidChange: ((PlaybackState) -> Void)? {
        get { inner.stateDidChange }
        set { inner.stateDidChange = newValue }
    }

    func load(_ url: URL) throws {
        try load(source: DecoderSource(url: url))
    }

    func enqueue(_ url: URL) throws {
        try enqueue(source: DecoderSource(url: url))
    }

    func reload(url: URL, at time: TimeInterval, resumePlaying: Bool) throws {
        try reload(source: DecoderSource(url: url), at: time, resumePlaying: resumePlaying)
    }

    func load(source: DecoderSource) throws {
        try inner.load(source: source)
        loadedURLs.append(source.url)
        loadedSources.append(source)
    }

    func enqueue(source: DecoderSource) throws {
        try inner.enqueue(source: source)
        enqueuedURLs.append(source.url)
        enqueuedSources.append(source)
    }

    func reload(source: DecoderSource, at time: TimeInterval, resumePlaying: Bool) throws {
        try inner.reload(source: source, at: time, resumePlaying: resumePlaying)
        reloadedURLs.append(source.url)
        reloadedSources.append(source)
    }

    func play() {
        inner.play()
    }

    func pause() {
        inner.pause()
    }

    func stop() {
        inner.stop()
    }

    func seek(to time: TimeInterval) {
        inner.seek(to: time)
    }

    func setBandGain(_ index: Int, dB decibels: Float) {
        inner.setBandGain(index, dB: decibels)
    }

    func setGlobalGain(_ decibels: Float) {
        inner.setGlobalGain(decibels)
    }

    var volume: Float {
        inner.volume
    }

    func setVolume(_ newVolume: Float) {
        inner.setVolume(newVolume)
    }

    var balance: Float {
        inner.balance
    }

    func setBalance(_ newBalance: Float) {
        inner.setBalance(newBalance)
    }

    var onEndOfAudio: (() -> Void)? {
        get { inner.onEndOfAudio }
        set { inner.onEndOfAudio = newValue }
    }

    var onRenderingComplete: (() -> Void)? {
        get { inner.onRenderingComplete }
        set { inner.onRenderingComplete = newValue }
    }
}

extension TrackRef {
    /// A deterministic, file-free ref whose path passes the fake decoder.
    static func fixture(_ name: String, availability: Availability = .present) -> TrackRef {
        TrackRef(filePath: "/fixtures/\(name).fake", title: name, availability: availability)
    }
}

/// Records the snapshots delivered to ``PlaybackCoordinating/stateDidChange``.
@MainActor
final class StateRecorder {
    private(set) var states: [CoordinatorState] = []

    func record(_ state: CoordinatorState) {
        states.append(state)
    }
}
