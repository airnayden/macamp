// CUE segment playback through the coordinator (todo 31): the frame range reaching
// the engine, same-file gapless, the seek clamp, and the two identity fixes.
//
// Hermetic throughout — `FakeDecoderProvider` honours a frame range and
// `FakePlaybackEngine` derives its duration from the resolved decoder's
// `frameLength`, so a segment's own length is observable with no audio hardware and
// no binary fixture.
import AudioEngine
import AVFAudio
import Foundation
import Models
import Persistence
import PlayerCoreTestSupport
import Separation
@testable import Services
import Testing

/// The karaoke model digest the fake cache's keys are derived from. At file scope
/// because ``TempDisc`` is nonisolated and cannot read a `@MainActor` static.
private let testModelSHA = "test-model-sha"

@MainActor
@Suite(.serialized)
struct CueSegmentPlaybackTests {
    private static let sampleRate = 44100
    private static let discPath = "/fixtures/disc.fake"

    /// CD frames, the unit `track.cueStartFrame` stores: 75 per second, so ten
    /// seconds is 750 and the sample conversion is `frames · rate / 75`.
    private static let tenSecondsInCueFrames = 750

    private static func segment(
        _ number: Int,
        startSeconds: Int,
        endSeconds: Int?,
        path: String = discPath
    ) -> TrackRef {
        TrackRef(
            trackID: Int64(number),
            filePath: path,
            title: "Track \(number)",
            sampleRate: sampleRate,
            cueStartFrame: Int64(startSeconds * CueTime.framesPerSecond),
            cueEndFrame: endSeconds.map { Int64($0 * CueTime.framesPerSecond) }
        )
    }

    private static func samples(seconds: Int) -> AVAudioFramePosition {
        AVAudioFramePosition(seconds * sampleRate)
    }

    private func makeEngine() -> SpyPlaybackEngine {
        SpyPlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 30))
    }

    // MARK: Frame range → engine

    @Test("activating a cue segment loads only that region of the disc image")
    func activationLoadsOnlyTheSegmentRegion() {
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)

        coordinator.setQueue([Self.segment(1, startSeconds: 0, endSeconds: 10)], startingAt: 0)

        #expect(engine.loadedSources.last?.url == URL(fileURLWithPath: Self.discPath))
        #expect(engine.loadedSources.last?.frameRange == 0 ..< Self.samples(seconds: 10))
        #expect(abs(coordinator.duration - 10) < 0.01)
    }

    @Test("a whole-file ref still loads the whole stream")
    func wholeFileRefLoadsTheWholeStream() {
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)

        coordinator.setQueue([TrackRef.fixture("whole")], startingAt: 0)

        #expect(engine.loadedSources.last?.frameRange == nil)
        #expect(abs(coordinator.duration - 30) < 0.01)
    }

    @Test("a manual-queue cue segment loads its region too")
    func manualQueueSegmentLoadsItsRegion() {
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)

        coordinator.enqueueManual(Self.segment(2, startSeconds: 10, endSeconds: 20))
        coordinator.playManual(at: 0)

        #expect(engine.loadedSources.last?.frameRange == Self.samples(seconds: 10) ..< Self.samples(seconds: 20))
    }

    // MARK: Same-file gapless

    @Test("gapless pre-scheduling enqueues the NEXT segment's region of the same file")
    func sameFileGaplessEnqueuesTheNextSegmentRegion() throws {
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.setQueue(
            [
                Self.segment(1, startSeconds: 0, endSeconds: 10),
                Self.segment(2, startSeconds: 10, endSeconds: 20),
            ],
            startingAt: 0
        )

        engine.onRenderingComplete?()

        let enqueued = try #require(engine.enqueuedSources.last)
        // URL-equal is the whole point: the successor differs only by its region, so
        // what reaches the player must be a distinct DECODER, not a distinct URL.
        #expect(enqueued.url == engine.loadedSources.last?.url)
        #expect(enqueued.frameRange == Self.samples(seconds: 10) ..< Self.samples(seconds: 20))
    }

    @Test("auto-advancing from one segment to the next loads the successor's region")
    func autoAdvanceLoadsTheSuccessorRegion() {
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.setQueue(
            [
                Self.segment(1, startSeconds: 0, endSeconds: 10),
                Self.segment(2, startSeconds: 10, endSeconds: 20),
            ],
            startingAt: 0
        )

        engine.onEndOfAudio?()

        #expect(coordinator.current?.trackID == 2)
        #expect(engine.loadedSources.last?.frameRange == Self.samples(seconds: 10) ..< Self.samples(seconds: 20))
    }

    // MARK: Seek clamping

    @Test("seeking past a segment's end clamps to that end, and reports the clamped value")
    func seekBeyondTheSegmentClampsToItsEnd() {
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let recorder = SeekRecorder()
        coordinator.onSeek = { origin, target in recorder.record(from: origin, to: target) }
        coordinator.setQueue([Self.segment(2, startSeconds: 10, endSeconds: 20)], startingAt: 0)

        coordinator.seek(to: 25)

        #expect(abs(coordinator.currentTime - 10) < 0.001)
        #expect(recorder.lastTo.map { abs($0 - 10) < 0.001 } == true)
    }

    @Test("seeking before a segment's start clamps to zero")
    func seekBeforeTheSegmentClampsToZero() {
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.setQueue([Self.segment(2, startSeconds: 10, endSeconds: 20)], startingAt: 0)

        coordinator.seek(to: -5)

        #expect(coordinator.currentTime == 0)
    }

    @Test("a whole-file seek is reported unclamped, exactly as before")
    func wholeFileSeekIsUnchanged() {
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(engine: engine)
        let recorder = SeekRecorder()
        coordinator.onSeek = { origin, target in recorder.record(from: origin, to: target) }
        coordinator.setQueue([TrackRef.fixture("whole")], startingAt: 0)

        coordinator.seek(to: 12.5)

        #expect(recorder.lastTo == 12.5)
    }

    // MARK: Frame conversion

    @Test("cue CD frames convert to samples, and an open end reports the sentinel upper bound")
    func segmentFrameRangeConvertsCueFramesToSamples() {
        let bounded = Self.segment(2, startSeconds: 10, endSeconds: 20)
        let openEnded = Self.segment(3, startSeconds: 20, endSeconds: nil)

        #expect(bounded.cueStartFrame == Int64(Self.tenSecondsInCueFrames))
        #expect(bounded.segmentFrameRange == Self.samples(seconds: 10) ..< Self.samples(seconds: 20))
        #expect(openEnded.segmentFrameRange == Self.samples(seconds: 20) ..< AVAudioFramePosition.max)
        #expect(TrackRef.fixture("whole").segmentFrameRange == nil)
    }

    @Test("a ref with no known sample rate falls back to the whole file rather than to nothing")
    func refWithoutSampleRateFallsBackToTheWholeFile() {
        let rateless = TrackRef(
            filePath: Self.discPath,
            cueStartFrame: Int64(Self.tenSecondsInCueFrames),
            cueEndFrame: Int64(2 * Self.tenSecondsInCueFrames)
        )

        #expect(rateless.isCueSegment)
        #expect(rateless.segmentFrameRange == nil)
    }

    @Test("a cue segment and the whole-file row on the same path are different identities")
    func segmentAndWholeFileRowAreDifferentIdentities() {
        let whole = TrackRef(filePath: Self.discPath, sampleRate: Self.sampleRate)
        let segment = Self.segment(2, startSeconds: 10, endSeconds: 20)

        #expect(whole.identity.cueStartFrame == TrackRecord.wholeFileCueStartFrame)
        #expect(segment.identity.cueStartFrame == Int64(Self.tenSecondsInCueFrames))
        #expect(whole.identity != segment.identity)
    }

    // MARK: Karaoke is never offered for a cue segment

    @Test("a cue segment resolves no instrumental, so engaging karaoke auto-deactivates")
    func cueSegmentNeverResolvesAnInstrumental() async throws {
        let disc = try TempDisc()
        defer { disc.remove() }
        let cache = FakeInstrumentalCache(seeded: [disc.key: disc.instrumentalURL])
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            instrumentalCache: cache,
            karaokeModelSHA: testModelSHA,
            karaokeSeparatorAvailable: true
        )
        coordinator.karaokeDebounceInterval = .milliseconds(20)
        let notice = AutoDeactivateRecorder()
        coordinator.onKaraokeAutoDeactivated = { notice.record() }
        coordinator.setQueue(
            [Self.segment(1, startSeconds: 0, endSeconds: 10, path: disc.path)],
            startingAt: 0
        )

        coordinator.setKaraokeActive(true)
        await coordinator.karaokeDebounceTask?.value

        #expect(!coordinator.karaokeActive)
        #expect(notice.count == 1)
        #expect(engine.reloadedSources.isEmpty)
    }

    /// The exact failure the old `[filePath: URL]` map produced: a suppressed
    /// whole-file row and a cue segment share one path, so a path-keyed map handed
    /// the segment the whole file's instrumental. Keyed by identity, the whole-file
    /// row resolves and the segment stays absent.
    @Test("a suppressed whole-file row resolves an instrumental while its own segments do not")
    func instrumentalsAreKeyedByIdentityNotPath() async throws {
        let disc = try TempDisc()
        defer { disc.remove() }
        let cache = FakeInstrumentalCache(seeded: [disc.key: disc.instrumentalURL])
        let engine = makeEngine()
        let coordinator = PlaybackCoordinator(
            engine: engine,
            instrumentalCache: cache,
            karaokeModelSHA: testModelSHA,
            karaokeSeparatorAvailable: true
        )
        coordinator.karaokeDebounceInterval = .milliseconds(20)
        let whole = TrackRef(trackID: 9, filePath: disc.path, sampleRate: Self.sampleRate)
        let segment = Self.segment(1, startSeconds: 0, endSeconds: 10, path: disc.path)
        coordinator.setQueue([whole, segment], startingAt: 0)

        coordinator.setKaraokeActive(true)
        await coordinator.karaokeDebounceTask?.value

        #expect(coordinator.karaokeActive)
        #expect(coordinator.resolvedInstrumentals[whole.identity] == disc.instrumentalURL)
        #expect(coordinator.resolvedInstrumentals[segment.identity] == nil)
        #expect(engine.reloadedSources.map(\.url) == [disc.instrumentalURL])
        // The successor is the segment, which has no instrumental: it is pre-scheduled
        // as its own region of the original file.
        #expect(engine.enqueuedSources.last?.url == URL(fileURLWithPath: disc.path))
        #expect(engine.enqueuedSources.last?.frameRange == 0 ..< Self.samples(seconds: 10))
    }
}

// MARK: - Recorders + temp disc image

/// Escaping coordinator callbacks cannot capture a mutable local under strict
/// concurrency, so each observation lands in a main-actor box.
@MainActor
private final class SeekRecorder {
    private(set) var lastTo: TimeInterval?

    func record(from _: TimeInterval, to target: TimeInterval) {
        lastTo = target
    }
}

@MainActor
private final class AutoDeactivateRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

/// A real on-disk file for the disc image plus its instrumental, because
/// ``SeparationCacheKey`` fingerprints the file's size and mtime — a synthetic path
/// would derive a different key from the one seeded into the fake cache.
private struct TempDisc {
    let path: String
    let instrumentalURL: URL
    let key: SeparationCacheKey

    private let originalURL: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString
        originalURL = directory.appendingPathComponent("cue-disc-\(stamp).flac")
        try Data("disc-image".utf8).write(to: originalURL)
        instrumentalURL = directory.appendingPathComponent("cue-disc-instr-\(stamp).m4a")
        try Data("instrumental".utf8).write(to: instrumentalURL)
        path = originalURL.path
        key = try SeparationCacheKey(url: originalURL, modelSHA: testModelSHA)
    }

    func remove() {
        try? FileManager.default.removeItem(at: originalURL)
        try? FileManager.default.removeItem(at: instrumentalURL)
    }
}
