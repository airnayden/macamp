// ReplayGainPlaybackPathTests — the WHOLE path, not the unit.
//
// `ReplayGainFallbackTests` next door proves the three-rung resolution in isolation
// against a stub cache and a hand-built `TrackMetadata`. This suite proves the thing
// that was missing until the composition roots were wired: a real `AppDatabase`, a
// real `TrackLoudnessRepository` as the cache, a real `PlaybackCoordinator` track
// change, and the dB that actually lands on the engine's `GainComposer`.
//
// The harness installs the same `stateDidChange` hook both shells install (see
// `macOS/Sources/AppEnvironment+ReplayGain.swift`), including the same rung-1 read of
// the persisted `track.replaygain*` columns and the same cue-aware segment mapping.
// That the SHELL installs it is proven separately by
// `macOS/Tests/ReplayGainWiringTests.swift`, which drives the live composition root;
// this suite owns the portable half so `swift test` covers it.
import AudioEngine
import Foundation
import GRDB
import Metadata
import Persistence
import Services
import Testing

@MainActor
@Suite(.serialized)
struct ReplayGainPlaybackPathTests {
    /// RG 2.0 normalises to −18 LUFS, so a −23 LUFS measurement asks for +5 dB, and
    /// a 0.5 true peak leaves +6.02 dB of head-room — the anti-clip limit does not
    /// bind.
    private let computedGain = 5.0

    @Test("a tagless but analysed track is normalised from the cache on track change")
    func cachedMeasurementReachesTheEngine() async throws {
        let harness = try PlaybackPathHarness()
        try await harness.analyse(integratedLUFS: -23, truePeak: 0.5)

        harness.playFirstTrack()
        await harness.settle()

        #expect(harness.replayGain.source == .computed)
        #expect(approxEqual(Double(harness.engine.gainComposer.replayGainDB), computedGain))
        #expect(approxEqual(Double(harness.engine.globalGain), computedGain))
    }

    @Test("the computed gain sums with the EQ pre-amp instead of replacing it")
    func computedGainSumsWithTheGraphicPreamp() async throws {
        let harness = try PlaybackPathHarness()
        try await harness.analyse(integratedLUFS: -23, truePeak: 0.5)
        harness.engine.gainComposer.setGraphicPreamp(-6)

        harness.playFirstTrack()
        await harness.settle()

        #expect(approxEqual(Double(harness.engine.gainComposer.replayGainDB), computedGain))
        #expect(approxEqual(Double(harness.engine.gainComposer.composedGainDB), -1.0))
        #expect(approxEqual(Double(harness.engine.globalGain), -1.0))
    }

    @Test("REPLAYGAIN_* tags the scanner persisted win over the cached measurement")
    func persistedTagsWinOverTheCache() async throws {
        let harness = try PlaybackPathHarness(tags: ReplayGain(trackGain: -7.5, trackPeak: 0.98))
        try await harness.analyse(integratedLUFS: -23, truePeak: 0.5)

        harness.playFirstTrack()
        await harness.settle()

        #expect(harness.replayGain.source == .tags)
        #expect(approxEqual(Double(harness.engine.globalGain), -7.5))
    }

    @Test("an untagged, unanalysed track plays at unity")
    func untaggedAndUnanalysedPlaysAtUnity() async throws {
        let harness = try PlaybackPathHarness()

        harness.playFirstTrack()
        await harness.settle()

        #expect(harness.replayGain.source == .unavailable)
        #expect(harness.engine.globalGain == 0)
    }

    @Test("a measurement taken over different cue bounds is refused, not served")
    func aForeignCueSegmentMeasurementIsRefused() async throws {
        let harness = try PlaybackPathHarness(cueStartFrame: 15000, cueEndFrame: 30000)
        try await harness.analyse(integratedLUFS: -23, truePeak: 0.5)

        harness.playFirstTrack()
        await harness.settle()

        #expect(harness.replayGain.source == .unavailable, "the row measures the whole file")
        #expect(harness.engine.globalGain == 0)
    }

    @Test("switching mode mid-track re-pushes without re-reading anything")
    func modeChangeRepushesTheCachedResolution() async throws {
        let harness = try PlaybackPathHarness()
        try await harness.analyse(integratedLUFS: -23, truePeak: 0.5, album: (lufs: -20, peak: 0.5))
        harness.playFirstTrack()
        await harness.settle()

        harness.replayGain.mode = .album
        harness.replayGain.reapply()

        #expect(harness.replayGain.source == .computed, "provenance survives a mode change")
        #expect(approxEqual(Double(harness.engine.globalGain), 2.0), "−18 − (−20)")
    }

    @Test("clearing the queue returns the ReplayGain summand to unity; stopping does not")
    func emptyingTheQueueReturnsToUnity() async throws {
        let harness = try PlaybackPathHarness()
        try await harness.analyse(integratedLUFS: -23, truePeak: 0.5)
        harness.playFirstTrack()
        await harness.settle()
        #expect(harness.engine.globalGain != 0)

        // `stop()` keeps `current` — the track is still loaded and Play resumes it,
        // so re-deciding its gain would be re-deciding the same question.
        harness.coordinator.stop()
        await harness.settle()
        #expect(approxEqual(Double(harness.engine.gainComposer.replayGainDB), computedGain))

        harness.coordinator.removeAll()
        await harness.settle()

        #expect(harness.engine.gainComposer.replayGainDB == 0)
        #expect(harness.replayGain.source == .unavailable)
    }
}

// MARK: - Harness

/// A real database, a real coordinator and a real service, wired the way both
/// composition roots wire them.
@MainActor
final class PlaybackPathHarness {
    let database: AppDatabase
    let engine = FakePlaybackEngine()
    let coordinator: PlaybackCoordinator
    let replayGain: ReplayGainService
    let track: TrackRef

    /// The resolution the hook started, so a test awaits it rather than polling.
    private var pending: Task<Void, Never>?

    init(
        tags: ReplayGain? = nil,
        cueStartFrame: Int64? = nil,
        cueEndFrame: Int64? = nil,
        mode: ReplayGainMode = .track
    ) throws {
        let database = try AppDatabase.makeEmpty()
        self.database = database
        coordinator = PlaybackCoordinator(engine: engine)
        replayGain = ReplayGainService(
            engine: engine,
            loudnessCache: TrackLoudnessRepository(database),
            mode: mode
        )
        var record = TrackRecord(
            filePath: "/tmp/macamp-replaygain-path.flac",
            title: "Untagged",
            sampleRate: 44100,
            replaygainTrackGain: tags?.trackGain,
            replaygainTrackPeak: tags?.trackPeak,
            replaygainAlbumGain: tags?.albumGain,
            replaygainAlbumPeak: tags?.albumPeak,
            cueStartFrame: cueStartFrame ?? TrackRecord.wholeFileCueStartFrame,
            cueEndFrame: cueEndFrame
        )
        try database.writer.write { db in try record.insert(db) }
        track = TrackRef(record: record)
        wire()
    }

    /// Seeds the v18 `trackLoudness` row a Loudness pass would have written.
    func analyse(
        integratedLUFS: Double?,
        truePeak: Double,
        album: (lufs: Double, peak: Double)? = nil
    ) async throws {
        let trackId = try #require(track.trackID)
        try await TrackLoudnessRepository(database).upsert(
            TrackLoudnessRecord(
                trackId: trackId,
                integratedLUFS: integratedLUFS,
                truePeak: truePeak,
                albumLUFS: album?.lufs,
                albumPeak: album?.peak,
                analysisVersion: 1,
                fingerprint: TrackLoudnessFingerprint(fileSize: 1024, mtime: 0),
                computedAt: 0
            )
        )
    }

    func playFirstTrack() {
        coordinator.setQueue([track], startingAt: 0)
    }

    /// Awaits the in-flight resolution — deterministic, so no timeout is needed.
    func settle() async {
        await pending?.value
    }
}

private extension PlaybackPathHarness {
    /// The shells' hook, verbatim in shape: chain after `previous`, latch on the ref
    /// identity, resolve rung 1 off-main, then hand the rest to the service.
    func wire() {
        let previous = coordinator.stateDidChange
        var currentRefID: UUID?
        coordinator.stateDidChange = { [weak self] state in
            previous?(state)
            guard let self, state.current?.id != currentRefID else { return }
            currentRefID = state.current?.id
            pending?.cancel()
            guard let playing = state.current else {
                replayGain.apply(ReplayGain())
                pending = nil
                return
            }
            pending = resolution(for: playing)
        }
    }

    func resolution(for playing: TrackRef) -> Task<Void, Never> {
        let writer = database.writer
        let segment = Self.segment(for: playing)
        let trackID = playing.trackID
        let service = replayGain
        return Task { @MainActor in
            let tags = await Self.persistedTags(trackID: trackID, writer: writer)
            await service.apply(metadata: TrackMetadata(replayGain: tags), segment: segment)
        }
    }

    static func segment(for track: TrackRef) -> ReplayGainSegment? {
        guard let trackID = track.trackID, trackID > 0 else { return nil }
        guard let cueStartFrame = track.cueStartFrame else { return .wholeFile(trackId: trackID) }
        return ReplayGainSegment(
            trackId: trackID,
            cueStartFrame: cueStartFrame,
            cueEndFrame: track.cueEndFrame
        )
    }

    static func persistedTags(trackID: Int64?, writer: any DatabaseWriter) async -> ReplayGain? {
        guard let trackID, trackID > 0 else { return nil }
        let record = try? await writer.read { db in try TrackRecord.fetchOne(db, key: trackID) }
        guard let record else { return nil }
        let tags = ReplayGain(
            trackGain: record.replaygainTrackGain,
            trackPeak: record.replaygainTrackPeak,
            albumGain: record.replaygainAlbumGain,
            albumPeak: record.replaygainAlbumPeak
        )
        return tags.isEmpty ? nil : tags
    }
}
