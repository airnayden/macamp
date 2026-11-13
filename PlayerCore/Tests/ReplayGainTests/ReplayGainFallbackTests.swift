// ReplayGainFallbackTests — the three-rung resolution the playback path runs:
// REPLAYGAIN_* tags, then the v18 `trackLoudness` analysis cache, then unity.
//
// Driven through the file-free `FakePlaybackEngine` (which records the clamped
// `globalGain` it receives) and a stub cache, so nothing here opens a database
// or an audio file. The cache stub is an actor because `TrackLoudnessReading` is
// `Sendable` and the suite asserts on which track ids were looked up.
import AudioEngine // FakePlaybackEngine, globalGainRange
import Foundation
import Metadata // ReplayGain, TrackMetadata
import Persistence // TrackLoudnessRecord, TrackLoudnessFingerprint
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct ReplayGainFallbackTests {
    private let untagged = TrackMetadata(title: "Untagged")
    private let segment = ReplayGainSegment.wholeFile(trackId: 7)

    @Test("REPLAYGAIN_* tags win over a cached measurement")
    func tagsWinOverCache() async {
        let engine = FakePlaybackEngine()
        let cache = StubLoudnessCache(records: [7: .fixture(integratedLUFS: -23, truePeak: 0.5)])
        let service = ReplayGainService(engine: engine, loudnessCache: cache, mode: .track)
        let tagged = TrackMetadata(title: "Tagged", replayGain: ReplayGain(trackGain: -7.5, trackPeak: 0.98))

        let applied = await service.apply(metadata: tagged, segment: segment)

        #expect(approxEqual(applied, -7.5))
        #expect(approxEqual(Double(engine.globalGain), -7.5))
        #expect(service.source == .tags)
        let requested = await cache.requestedTrackIds
        #expect(requested.isEmpty, "rung 1 answered, so rung 2 must not be read")
    }

    @Test("an untagged track with a cached measurement uses the computed gain")
    func cachedMeasurementNormalises() async {
        let engine = FakePlaybackEngine()
        let cache = StubLoudnessCache(records: [7: .fixture(integratedLUFS: -23, truePeak: 0.5)])
        let service = ReplayGainService(engine: engine, loudnessCache: cache, mode: .track)

        let applied = await service.apply(metadata: untagged, segment: segment)

        #expect(approxEqual(applied, 5.0), "RG 2.0 track gain is −18 − (−23)")
        #expect(approxEqual(Double(engine.globalGain), 5.0))
        #expect(service.source == .computed)
        let requested = await cache.requestedTrackIds
        #expect(requested == [7])
    }

    @Test("an untagged, unanalysed track applies 0 dB")
    func untaggedAndUncachedAppliesUnity() async {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, loudnessCache: StubLoudnessCache(), mode: .track)

        let applied = await service.apply(metadata: untagged, segment: segment)

        #expect(applied == 0)
        #expect(engine.globalGain == 0)
        #expect(service.source == .unavailable)
    }

    @Test("reapply() still honors mode and pre-amp changes after a cached resolution")
    func reapplyHonorsSettingsAfterCachedResolution() async {
        let engine = FakePlaybackEngine()
        let record = TrackLoudnessRecord.fixture(
            integratedLUFS: -23,
            truePeak: 0.5,
            album: (lufs: -20, peak: 0.5)
        )
        let service = ReplayGainService(
            engine: engine,
            loudnessCache: StubLoudnessCache(records: [7: record]),
            mode: .track
        )
        let first = await service.apply(metadata: untagged, segment: segment)
        #expect(approxEqual(first, 5.0))

        service.mode = .album
        #expect(approxEqual(service.reapply(), 2.0), "album gain is −18 − (−20)")
        #expect(approxEqual(Double(engine.globalGain), 2.0))

        service.mode = .track
        service.preamp = -3
        #expect(approxEqual(service.reapply(), 2.0), "track gain +5 trimmed by a −3 pre-amp")
        #expect(approxEqual(Double(engine.globalGain), 2.0))
        #expect(service.source == .computed, "re-computing does not change where the values came from")
    }

    @Test("an absurd cached loudness still clamps into the engine's −96…+24 dB range")
    func absurdCachedLoudnessClamps() async {
        let engine = FakePlaybackEngine()
        // −18 − (−80) = +62 dB, and a peak that low leaves an +80 dB anti-clip
        // ceiling — so the engine clamp is the only bound left to catch this.
        let cache = StubLoudnessCache(records: [7: .fixture(integratedLUFS: -80, truePeak: 0.0001)])
        let service = ReplayGainService(engine: engine, loudnessCache: cache, mode: .track)

        let applied = await service.apply(metadata: untagged, segment: segment)

        #expect(approxEqual(applied, Double(globalGainRange.upperBound)))
        #expect(applied >= Double(globalGainRange.lowerBound))
        #expect(applied <= Double(globalGainRange.upperBound))
        #expect(approxEqual(Double(engine.globalGain), 24))
    }

    @Test("the anti-clip limit still bounds a cached measurement")
    func cachedMeasurementIsAntiClipped() async {
        let engine = FakePlaybackEngine()
        // −18 − (−30) = +12 dB, but a 0.95 peak leaves only +0.4455 dB of headroom.
        let cache = StubLoudnessCache(records: [7: .fixture(integratedLUFS: -30, truePeak: 0.95)])
        let service = ReplayGainService(engine: engine, loudnessCache: cache, mode: .track)

        let applied = await service.apply(metadata: untagged, segment: segment)

        #expect(applied < 12, "the calculator was bypassed if the raw +12 dB got through")
        let projectedPeak = 0.95 * pow(10.0, Double(engine.globalGain) / 20.0)
        #expect(projectedPeak <= 1.0 + 1e-6, "engine gain would clip: \(projectedPeak)")
    }

    @Test("off mode pushes unity even with a cached measurement")
    func offModeIgnoresCachedMeasurement() async {
        let engine = FakePlaybackEngine()
        let cache = StubLoudnessCache(records: [7: .fixture(integratedLUFS: -23, truePeak: 0.5)])
        let service = ReplayGainService(engine: engine, loudnessCache: cache, mode: .off, preamp: 6)

        let applied = await service.apply(metadata: untagged, segment: segment)

        #expect(applied == 0)
        #expect(engine.globalGain == 0)
        #expect(service.source == .computed, "the values were found; the mode chose not to use them")
    }

    @Test("a row measured over different cue bounds is not served")
    func cueMismatchFallsThroughToUnity() async {
        let engine = FakePlaybackEngine()
        let record = TrackLoudnessRecord.fixture(integratedLUFS: -23, truePeak: 0.5, cueStartFrame: 1000)
        let service = ReplayGainService(
            engine: engine,
            loudnessCache: StubLoudnessCache(records: [7: record]),
            mode: .track
        )

        let applied = await service.apply(metadata: untagged, segment: segment)

        #expect(applied == 0)
        #expect(service.source == .unavailable)
    }

    @Test("a cache read failure degrades to unity instead of failing playback")
    func cacheFailureDegradesToUnity() async {
        let engine = FakePlaybackEngine()
        let cache = StubLoudnessCache(failure: StubCacheError.unreadable)
        let service = ReplayGainService(engine: engine, loudnessCache: cache, mode: .track)

        let applied = await service.apply(metadata: untagged, segment: segment)

        #expect(applied == 0)
        #expect(service.source == .unavailable)
    }

    @Test("a track with no library row never reads the cache")
    func nonLibraryTrackNeverReadsTheCache() async {
        let engine = FakePlaybackEngine()
        let cache = StubLoudnessCache(records: [7: .fixture(integratedLUFS: -23, truePeak: 0.5)])
        let service = ReplayGainService(engine: engine, loudnessCache: cache, mode: .track)

        let withoutSegment = await service.apply(metadata: untagged, segment: nil)
        let withSentinelID = await service.apply(metadata: untagged, segment: .wholeFile(trackId: 0))

        #expect(withoutSegment == 0)
        #expect(withSentinelID == 0)
        let requested = await cache.requestedTrackIds
        #expect(requested.isEmpty)
    }

    @Test("resolve() reports provenance without touching the engine")
    func resolveReportsProvenanceWithoutPushing() async {
        let engine = FakePlaybackEngine()
        let cache = StubLoudnessCache(records: [7: .fixture(integratedLUFS: -23, truePeak: 0.5)])
        let service = ReplayGainService(engine: engine, loudnessCache: cache, mode: .track)

        let resolution = await service.resolve(metadata: untagged, segment: segment)

        #expect(resolution.source == .computed)
        #expect(approxEqual(resolution.tags.trackGain ?? .nan, 5.0))
        #expect(engine.globalGain == 0, "never pushed")
        #expect(service.source == .unavailable, "resolving is not applying")
    }

    @Test("a service with no cache resolves tags or unity")
    func withoutACacheOnlyTagsResolve() async {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .track)

        let applied = await service.apply(metadata: untagged, segment: segment)

        #expect(applied == 0)
        #expect(service.source == .unavailable)
    }
}

// MARK: - Doubles

private enum StubCacheError: Error {
    case unreadable
}

/// A ``TrackLoudnessReading`` over an in-memory table, recording every lookup.
private actor StubLoudnessCache: TrackLoudnessReading {
    private let records: [Int64: TrackLoudnessRecord]
    private let failure: (any Error)?
    private(set) var requestedTrackIds: [Int64] = []

    init(records: [Int64: TrackLoudnessRecord] = [:], failure: (any Error)? = nil) {
        self.records = records
        self.failure = failure
    }

    func loudness(forTrackId trackId: Int64) async throws -> TrackLoudnessRecord? {
        requestedTrackIds.append(trackId)
        if let failure { throw failure }
        return records[trackId]
    }
}

private extension TrackLoudnessRecord {
    /// A row for track 7, carrying only the fields the resolution reads.
    static func fixture(
        integratedLUFS: Double?,
        truePeak: Double,
        album: (lufs: Double, peak: Double)? = nil,
        cueStartFrame: Int64 = TrackLoudnessFingerprint.wholeFileCueStartFrame
    ) -> TrackLoudnessRecord {
        TrackLoudnessRecord(
            trackId: 7,
            integratedLUFS: integratedLUFS,
            truePeak: truePeak,
            albumLUFS: album?.lufs,
            albumPeak: album?.peak,
            analysisVersion: 1,
            fingerprint: TrackLoudnessFingerprint(fileSize: 1024, mtime: 0, cueStartFrame: cueStartFrame),
            computedAt: 0
        )
    }
}
