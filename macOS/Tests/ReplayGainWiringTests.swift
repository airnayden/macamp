// ReplayGainWiringTests — that the SHELL calls the ReplayGain service, not just that
// the service is correct.
//
// `ReplayGainService` shipped fully unit-tested and fully unreachable: the
// composition root constructed it and nothing ever called `apply`/`reapply` or
// pushed the selected mode, so a tagless-but-analysed library played at unity no
// matter what the Loudness pass had measured. Unit tests could not catch that — the
// gap was the absence of a call site, so only a test that drives the LIVE
// composition root can close it.
//
// `AppEnvironment.preview()` is that root: the same `init` → `finishWiring` →
// `wireReplayGain` path `live()` runs, over an in-memory database and a
// `FakePlaybackEngine` that records the `globalGain` it is handed.
import AudioEngine
import Foundation
import GRDB
@testable import MacAMP
import Metadata
import Persistence
import Services
import Testing

@MainActor
@Suite("ReplayGainWiringTests", .serialized)
struct ReplayGainWiringTests {
    /// RG 2.0 normalises to −18 LUFS, so −23 LUFS asks for +5 dB; a 0.5 true peak
    /// leaves +6.02 dB of head-room, so the anti-clip limit does not bind.
    private let computedTrackGain: Float = 5.0

    @Test("the composition root normalises a tagless, analysed track on track change")
    func compositionRootAppliesTheCachedMeasurement() async throws {
        let environment = AppEnvironment.preview()
        let track = try await environment.seedAnalysedTrack(integratedLUFS: -23, truePeak: 0.5)
        environment.equalizer.setReplayGainMode(.track)

        environment.coordinator.setQueue([track], startingAt: 0)
        await environment.settle { $0.replayGain.source == .computed }

        #expect(environment.replayGain.source == .computed)
        #expect(abs(environment.engine.gainComposer.replayGainDB - computedTrackGain) < 0.001)
        let engine = try #require(environment.engine as? FakePlaybackEngine)
        #expect(abs(engine.globalGain - computedTrackGain) < 0.001)
    }

    @Test("picking a different mode re-pushes the gain without a new track change")
    func modeChangeReachesTheEngine() async throws {
        let environment = AppEnvironment.preview()
        let track = try await environment.seedAnalysedTrack(
            integratedLUFS: -23,
            truePeak: 0.5,
            album: (lufs: -20, peak: 0.5)
        )
        environment.equalizer.setReplayGainMode(.track)
        environment.coordinator.setQueue([track], startingAt: 0)
        await environment.settle { $0.replayGain.source == .computed }

        environment.equalizer.setReplayGainMode(.album)
        await environment.settle { abs($0.engine.gainComposer.replayGainDB - 2.0) < 0.001 }

        #expect(abs(environment.engine.gainComposer.replayGainDB - 2.0) < 0.001, "−18 − (−20)")
        #expect(environment.replayGain.source == .computed, "provenance survives a mode change")
    }

    @Test("ReplayGain off leaves the signal at unity even for an analysed track")
    func offModeLeavesTheGainAtUnity() async throws {
        let environment = AppEnvironment.preview()
        let track = try await environment.seedAnalysedTrack(integratedLUFS: -23, truePeak: 0.5)
        environment.equalizer.setReplayGainMode(.off)

        environment.coordinator.setQueue([track], startingAt: 0)
        await environment.settle { $0.replayGain.source == .computed }

        #expect(environment.engine.gainComposer.replayGainDB == 0)
    }
}

// MARK: - Fixtures

private extension AppEnvironment {
    /// A library track carrying NO ReplayGain tags plus the v18 `trackLoudness` row a
    /// Loudness pass would have written for it — the exact shape rung 2 exists for.
    func seedAnalysedTrack(
        integratedLUFS: Double?,
        truePeak: Double,
        album: (lufs: Double, peak: Double)? = nil
    ) async throws -> TrackRef {
        let record = try await database.writer.write { db -> TrackRecord in
            var row = TrackRecord(
                filePath: "/tmp/macamp-replaygain-wiring.flac",
                title: "Untagged",
                sampleRate: 44100
            )
            try row.insert(db)
            return row
        }
        let trackId = try #require(record.id)
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
        return TrackRef(record: record)
    }

    /// Both seams under test land asynchronously — the per-track resolve through a
    /// database read, the mode follow through `withObservationTracking`'s main-actor
    /// hop — so a test waits on the outcome rather than on a fixed sleep.
    func settle(timeout: Duration = .seconds(5), until condition: (AppEnvironment) -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, !condition(self) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
