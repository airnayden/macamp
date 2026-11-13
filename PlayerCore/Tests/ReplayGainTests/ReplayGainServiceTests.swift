// ReplayGainServiceTests — the service that computes the gain and hands it to an
// injected ``PlaybackEngine``. Driven through the file-free ``FakePlaybackEngine``
// (AudioEngine), which records the clamped ``globalGain`` it receives.
import AudioEngine // FakePlaybackEngine, PlaybackEngine
import Foundation
import Metadata // ReplayGain, TrackMetadata, FakeMetadataReader
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct ReplayGainServiceTests {
    private let full = ReplayGain(
        trackGain: -7.5,
        trackPeak: 0.98,
        albumGain: -8.2,
        albumPeak: 0.99
    )

    @Test("apply(_:) computes and pushes the track gain to the engine")
    func appliesTrackGainToEngine() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .track)
        let applied = service.apply(full)
        #expect(approxEqual(applied, -7.5))
        #expect(approxEqual(Double(engine.globalGain), applied))
    }

    @Test("album mode pushes the album gain")
    func appliesAlbumGain() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .album)
        let applied = service.apply(full)
        #expect(approxEqual(applied, -8.2))
        #expect(approxEqual(Double(engine.globalGain), -8.2))
    }

    @Test("apply(metadata:) reads the ReplayGain field off TrackMetadata")
    func appliesFromMetadata() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .track)
        // The Beatles fixture carries trackGain -7.5.
        let applied = service.apply(metadata: FakeMetadataReader.defaultMetadata)
        #expect(approxEqual(applied, -7.5))
        #expect(approxEqual(Double(engine.globalGain), -7.5))
    }

    @Test("missing ReplayGain tags fall back to 0 dB without crashing")
    func missingTagsApplyZero() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .track)
        let untagged = TrackMetadata(title: "Untagged") // replayGain == nil
        let applied = service.apply(metadata: untagged)
        #expect(applied == 0)
        #expect(engine.globalGain == 0)
    }

    @Test("off mode pushes unity even with tags present")
    func offModeAppliesUnity() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .off, preamp: 6)
        let applied = service.apply(full)
        #expect(applied == 0)
        #expect(engine.globalGain == 0)
    }

    @Test("reapply() re-pushes the last tags after a mode change")
    func reapplyAfterModeChange() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .track)
        #expect(approxEqual(service.apply(full), -7.5))

        service.mode = .album
        let applied = service.reapply()
        #expect(approxEqual(applied, -8.2))
        #expect(approxEqual(Double(engine.globalGain), -8.2))
    }

    @Test("reapply() re-pushes after a pre-amp change")
    func reapplyAfterPreampChange() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .track)
        service.apply(full)

        service.preamp = 3
        let applied = service.reapply()
        #expect(approxEqual(applied, -4.5))
        #expect(approxEqual(Double(engine.globalGain), -4.5))
    }

    @Test("the engine receives the anti-clipped value, never the raw boost")
    func antiClipReachesEngine() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .track)
        let hot = ReplayGain(trackGain: 12, trackPeak: 0.9)
        let applied = service.apply(hot)
        #expect(applied < 12)
        let projectedPeak = 0.9 * pow(10.0, Double(engine.globalGain) / 20.0)
        #expect(projectedPeak <= 1.0 + 1e-6, "engine gain would clip: \(projectedPeak)")
    }

    @Test("computedGain(for:) previews without touching the engine")
    func computedGainDoesNotTouchEngine() {
        let engine = FakePlaybackEngine()
        let service = ReplayGainService(engine: engine, mode: .track)
        let preview = service.computedGain(for: full)
        #expect(approxEqual(preview, -7.5))
        #expect(engine.globalGain == 0) // never pushed
    }
}
