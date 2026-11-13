// GainComposerTests — the single-writer gain ledger. Four contributors write
// their own summand; the composer sums, clamps once, and is the only code that
// reaches ``PlaybackEngine/setGlobalGain(_:)``. Driven through the file-free
// ``FakePlaybackEngine``, whose recorded `globalGain` is exactly what
// `SFBPlaybackEngine`'s `GlobalGainBox` would hold.
import AudioEngine // FakePlaybackEngine, GainComposer, globalGainRange
import Foundation
import Metadata // ReplayGain
@testable import Services
import Testing

@MainActor
@Suite(.serialized)
struct GainComposerTests {
    @Test("all four contributions sum into one composed gain")
    func contributionsSum() {
        let engine = FakePlaybackEngine()
        let composer = engine.gainComposer

        composer.setReplayGain(-4)
        composer.setGraphicPreamp(-6)
        composer.setParametricPreamp(-2)
        composer.setHeadroomTrim(-1)

        #expect(approxEqual(Double(composer.composedGainDB), -13))
        #expect(approxEqual(Double(engine.globalGain), -13))
    }

    @Test("composedGainDB is what the engine is holding after every write")
    func composedGainTracksEngine() {
        let engine = FakePlaybackEngine()
        let composer = engine.gainComposer

        composer.setReplayGain(-7.5)
        #expect(engine.globalGain == composer.composedGainDB)

        composer.setGraphicPreamp(3)
        #expect(engine.globalGain == composer.composedGainDB)
    }

    @Test("a contributor replaces only its own summand")
    func contributorsAreIndependent() {
        let engine = FakePlaybackEngine()
        let composer = engine.gainComposer

        composer.setGraphicPreamp(-6)
        composer.setReplayGain(-4)
        composer.setReplayGain(-9)

        #expect(composer.graphicPreampDB == -6)
        #expect(composer.replayGainDB == -9)
        #expect(approxEqual(Double(engine.globalGain), -15))
    }

    @Test("a sum above the ceiling clamps to exactly +24 dB")
    func sumClampsToUpperBound() {
        let engine = FakePlaybackEngine()
        let composer = engine.gainComposer

        composer.setReplayGain(20)
        composer.setGraphicPreamp(12)
        composer.setParametricPreamp(8)

        #expect(composer.composedGainDB == globalGainRange.upperBound)
        #expect(engine.globalGain == 24)
    }

    @Test("a sum below the floor clamps to exactly −96 dB")
    func sumClampsToLowerBound() {
        let engine = FakePlaybackEngine()
        let composer = engine.gainComposer

        composer.setReplayGain(-60)
        composer.setGraphicPreamp(-30)
        composer.setHeadroomTrim(-40)

        #expect(composer.composedGainDB == globalGainRange.lowerBound)
        #expect(engine.globalGain == -96)
    }

    @Test("clamping does not corrupt the individual summands")
    func clampingLeavesSummandsIntact() {
        let engine = FakePlaybackEngine()
        let composer = engine.gainComposer

        composer.setReplayGain(20)
        composer.setGraphicPreamp(12)
        #expect(composer.composedGainDB == 24)

        composer.setGraphicPreamp(-12)
        #expect(approxEqual(Double(composer.composedGainDB), 8))
    }

    @Test("one composer per engine, never shared between engines")
    func composerIsAttachedToItsEngine() {
        let engine = FakePlaybackEngine()
        let other = FakePlaybackEngine()

        #expect(engine.gainComposer === engine.gainComposer)
        #expect(engine.gainComposer !== other.gainComposer)

        engine.gainComposer.setGraphicPreamp(-6)
        #expect(other.gainComposer.graphicPreampDB == 0)
    }

    @Test("ReplayGainService contributes through the composer, not over it")
    func replayGainServiceWritesOnlyItsSummand() {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setGraphicPreamp(-6)
        let service = ReplayGainService(engine: engine, mode: .track)

        service.apply(ReplayGain(trackGain: -4))

        #expect(approxEqual(Double(engine.gainComposer.replayGainDB), -4))
        #expect(engine.gainComposer.graphicPreampDB == -6)
        #expect(approxEqual(Double(engine.globalGain), -10))
    }

    @Test("re-pushing ReplayGain on every track change preserves the preamp")
    func repeatedReplayGainPushesPreserveThePreamp() {
        let engine = FakePlaybackEngine()
        engine.gainComposer.setGraphicPreamp(-6)
        let service = ReplayGainService(engine: engine, mode: .track)

        for gain in [-4.0, -2.5, -8.0] {
            service.apply(ReplayGain(trackGain: gain))
            #expect(approxEqual(Double(engine.globalGain), gain - 6))
        }
    }
}
