import AudioEngine
import Metadata
import Persistence
import Services
import Testing
@testable import ViewModels

@MainActor
struct EQViewModelTests {
    @Test func applyingPresetSetsEngineBandGains() {
        let engine = FakePlaybackEngine()
        let model = EQViewModel(engine: engine, presetStore: FakeEQPresetStore())
        model.apply(.rock)
        #expect(engine.bandGains == EQPreset.rock.bandGains)
        #expect(model.bandGains == EQPreset.rock.bandGains)
        #expect(model.selectedPresetName == "Rock")
        #expect(engine.globalGain == (EQPreset.rock.preamp ?? 0))
    }

    @Test func setBandGainForwardsAndClearsPreset() {
        let engine = FakePlaybackEngine()
        let model = EQViewModel(engine: engine, presetStore: FakeEQPresetStore())
        model.apply(.flat)
        #expect(model.selectedPresetName == "Flat")
        model.setBandGain(3, dB: 6)
        #expect(engine.bandGains[3] == 6)
        #expect(model.bandGains[3] == 6)
        #expect(model.selectedPresetName == nil)
    }

    @Test func loadPresetsIncludesBuiltInsAndCustom() throws {
        let store = FakeEQPresetStore()
        try store.save(EQPreset(name: "Mine", bandGains: [Float](repeating: 1, count: 10)))
        let model = EQViewModel(engine: FakePlaybackEngine(), presetStore: store)
        model.loadPresets()
        #expect(model.presets.contains { $0.name == "Flat" })
        #expect(model.presets.contains { $0.name == "Mine" })
    }

    @Test func saveCustomPersistsAndSelects() throws {
        let store = FakeEQPresetStore()
        let model = EQViewModel(engine: FakePlaybackEngine(), presetStore: store)
        model.setBandGain(0, dB: 4)
        try model.saveCustomPreset(named: "Custom")
        #expect(model.selectedPresetName == "Custom")
        let persisted = try store.loadAll()
        #expect(persisted.contains { $0.name == "Custom" })
    }

    @Test func replayGainModeToggles() {
        let model = EQViewModel(engine: FakePlaybackEngine(), presetStore: FakeEQPresetStore())
        #expect(model.replayGainMode == .off)
        model.setReplayGainMode(.track)
        #expect(model.replayGainMode == .track)
    }

    /// THE DECISION RECORD for single gain ownership. The EQ preamp and the
    /// ReplayGain trim used to share one slot, so whichever wrote last erased the
    /// other — and because a track change re-pushes ReplayGain, the preamp was the
    /// one that always lost. They must now sum.
    @Test("preset preamp and ReplayGain sum, and the sum survives a track change")
    func preampAndReplayGainSumAcrossTrackChange() {
        let engine = FakePlaybackEngine()
        let eqModel = EQViewModel(engine: engine, presetStore: FakeEQPresetStore())
        let replayGain = ReplayGainService(engine: engine, mode: .track)
        let quietPreset = EQPreset(
            name: "Preamp −6",
            bandGains: [Float](repeating: 0, count: EQViewModel.bandCount),
            preamp: -6
        )

        eqModel.apply(quietPreset)
        replayGain.apply(ReplayGain(trackGain: -4))

        // A track change re-pushes the new decoder's tags, then `renderingWillStart`
        // re-stamps the engine's stored gain onto the EQ unit. `FakePlaybackEngine`
        // records exactly the value SFB's `GlobalGainBox` holds, so re-applying and
        // reading `globalGain` reproduces both halves of that hand-off.
        replayGain.apply(ReplayGain(trackGain: -4))
        let storedGlobalGain = engine.globalGain

        #expect(abs(storedGlobalGain - -10) < 0.001)
        #expect(eqModel.preamp == -6)
    }

    @Test("a preset applied mid-track keeps the ReplayGain trim")
    func presetAppliedAfterReplayGainKeepsBoth() {
        let engine = FakePlaybackEngine()
        let eqModel = EQViewModel(engine: engine, presetStore: FakeEQPresetStore())
        let replayGain = ReplayGainService(engine: engine, mode: .track)

        replayGain.apply(ReplayGain(trackGain: -4))
        eqModel.apply(.rock)

        let expected = -4 + (EQPreset.rock.preamp ?? 0)
        #expect(abs(engine.globalGain - expected) < 0.001)
    }
}
