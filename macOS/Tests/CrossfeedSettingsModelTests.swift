// CrossfeedSettingsModelTests — the crossfeed pane's model, without an audio device.
//
// `FakePlaybackEngine` ships inside `AudioEngine`, a shipping module, so the transport
// half needs no double at all (the `PlayerCoreTestSupport` link failure recorded for
// this target never bites). Each suite runs on its own volatile `UserDefaults` suite,
// so nothing here can read or write the developer's real preferences.
//
// NOTHING BELOW ASSERTS A CLAMP THIS FILE PERFORMS. The clamping is `CrossfeedLevel`'s,
// per component, and the round-trip tests exist to prove the model passes raw values
// THROUGH to it rather than pre-validating them into something else.
import AudioEngine
import DSP
import Foundation
@testable import MacAMP
import Testing

@MainActor
enum CrossfeedFixtures {
    /// A settings-free harness: the model owns its own scalars, so a suite needs only
    /// a private `UserDefaults` domain and a fake transport.
    @MainActor
    struct Harness {
        let defaults: UserDefaults
        let engine: FakePlaybackEngine
        let suiteName: String

        init(_ label: String) {
            suiteName = "com.example.macamp.tests.crossfeed.\(label).\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
            engine = FakePlaybackEngine()
        }

        /// Builds the model wired exactly as `connectCrossfeed()` wires it, so a
        /// divergence between production wiring and test wiring cannot hide here.
        func model(started: Bool = false) -> CrossfeedSettingsModel {
            let model = CrossfeedSettingsModel(defaults: defaults, engine: { engine })
            if started { model.start() }
            return model
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

// MARK: - Defaults

@MainActor
@Suite("Crossfeed preferences hydrate")
struct CrossfeedPreferencesLoadTests {
    @Test("a fresh install has crossfeed switched OFF")
    func freshDefaultsAreOff() {
        let harness = CrossfeedFixtures.Harness("fresh")
        defer { harness.tearDown() }

        let preferences = CrossfeedPreferences.load(from: harness.defaults)

        #expect(preferences.isEnabled == false)
        #expect(preferences.preset == .default)
        #expect(preferences.resolvedLevel == CrossfeedLevel.default)
    }

    @Test("a fresh install starts the stage disabled, so nothing is inserted")
    func startOnFreshDefaultsInsertsNothing() {
        let harness = CrossfeedFixtures.Harness("freshStart")
        defer { harness.tearDown() }

        _ = harness.model(started: true)

        #expect(harness.engine.crossfeedLevel == nil)
        #expect(harness.engine.requestedCrossfeedLevels == [nil])
    }

    @Test("an unreadable preset token degrades to Default and keeps the custom pair")
    func corruptPresetFallsBackToDefault() {
        let harness = CrossfeedFixtures.Harness("corruptPreset")
        defer { harness.tearDown() }
        harness.defaults.set("chu-moy-v2", forKey: AppSettingsKeys.crossfeedPreset)
        harness.defaults.set(1234.0, forKey: AppSettingsKeys.crossfeedCustomCutFrequency)
        harness.defaults.set(9.0, forKey: AppSettingsKeys.crossfeedCustomFeedDB)

        let preferences = CrossfeedPreferences.load(from: harness.defaults)

        #expect(preferences.preset == .default)
        #expect(preferences.resolvedLevel == CrossfeedLevel.default)
        #expect(preferences.customCutFrequency == 1234.0)
        #expect(preferences.customFeedDB == 9.0)
    }

    @Test("a non-string preset value degrades the same way")
    func nonStringPresetFallsBackToDefault() {
        let harness = CrossfeedFixtures.Harness("arrayPreset")
        defer { harness.tearDown() }
        harness.defaults.set(["cmoy"], forKey: AppSettingsKeys.crossfeedPreset)

        #expect(CrossfeedPreferences.load(from: harness.defaults).preset == .default)
    }

    /// An absent custom pair must read back as the Default preset's OWN numbers.
    /// `double(forKey:)` would answer `0` here, which `CrossfeedLevel` then clamps up
    /// to 300 Hz / 1 dB and presents as a choice somebody made.
    @Test("absent custom numbers hydrate to the Default preset's values, not zero")
    func absentCustomNumbersHydrateToDefault() {
        let harness = CrossfeedFixtures.Harness("absentCustom")
        defer { harness.tearDown() }

        let preferences = CrossfeedPreferences.load(from: harness.defaults)

        #expect(preferences.customCutFrequency == CrossfeedLevel.default.cutFrequency)
        #expect(preferences.customFeedDB == CrossfeedLevel.default.feedDB)
        #expect(preferences.customLevel == CrossfeedLevel.default)
    }

    @Test("every stored scalar survives a round trip")
    func persistThenLoadRoundTrips() {
        let harness = CrossfeedFixtures.Harness("roundTrip")
        defer { harness.tearDown() }
        let written = CrossfeedPreferences(
            isEnabled: true,
            preset: .custom,
            customCutFrequency: 512,
            customFeedDB: 7.25
        )

        written.persist(to: harness.defaults)

        #expect(CrossfeedPreferences.load(from: harness.defaults) == written)
    }
}

// MARK: - The engine seam

@MainActor
@Suite("Crossfeed reaches the engine")
struct CrossfeedSettingsModelEngineTests {
    @Test("switching crossfeed on inserts the stage at the Default preset")
    func enablingPublishesTheDefaultPreset() {
        let harness = CrossfeedFixtures.Harness("enable")
        defer { harness.tearDown() }
        let model = harness.model(started: true)

        model.preferences.isEnabled = true

        #expect(harness.engine.crossfeedLevel == CrossfeedLevel.default)
        #expect(model.programmedLevel == CrossfeedLevel.default)
    }

    @Test(
        "each preset publishes its own level",
        arguments: zip(
            [CrossfeedPreset.default, .cmoy, .jmeier],
            [CrossfeedLevel.default, .cmoy, .jmeier]
        )
    )
    func presetPublishesItsLevel(preset: CrossfeedPreset, level: CrossfeedLevel) {
        let harness = CrossfeedFixtures.Harness("preset.\(preset.rawValue)")
        defer { harness.tearDown() }
        let model = harness.model(started: true)

        model.preferences = CrossfeedPreferences(isEnabled: true, preset: preset)

        #expect(harness.engine.crossfeedLevel == level)
    }

    @Test("switching crossfeed off takes the stage back out")
    func disablingRemovesTheStage() {
        let harness = CrossfeedFixtures.Harness("disable")
        defer { harness.tearDown() }
        let model = harness.model(started: true)
        model.preferences.isEnabled = true

        model.preferences.isEnabled = false

        #expect(harness.engine.crossfeedLevel == nil)
        #expect(model.programmedLevel == nil)
        #expect(harness.engine.requestedCrossfeedLevels == [nil, CrossfeedLevel.default, nil])
    }

    /// The model hands raw slider values straight through; `CrossfeedLevel`'s
    /// initialiser is the only thing that bounds them, and it does so PER COMPONENT —
    /// so a legal frequency survives an illegal feed and vice versa.
    @Test("an out-of-range custom pair is programmed clamped, never refused")
    func customValuesClampOnTheWayThrough() throws {
        let harness = CrossfeedFixtures.Harness("clamp")
        defer { harness.tearDown() }
        let model = harness.model(started: true)

        model.preferences = CrossfeedPreferences(
            isEnabled: true,
            preset: .custom,
            customCutFrequency: 20000,
            customFeedDB: 0.25
        )

        let stored = model.programmedLevel
        let programmed = try #require(stored)
        #expect(programmed.cutFrequency == CrossfeedLevel.cutFrequencyRange.upperBound)
        #expect(programmed.feedDB == CrossfeedLevel.feedRange.lowerBound)
        #expect(model.preferences.customCutFrequency == 20000)
    }

    @Test("a legal component survives beside an illegal one")
    func clampIsPerComponent() {
        let harness = CrossfeedFixtures.Harness("perComponent")
        defer { harness.tearDown() }
        let model = harness.model(started: true)

        model.preferences = CrossfeedPreferences(
            isEnabled: true,
            preset: .custom,
            customCutFrequency: 650,
            customFeedDB: 99
        )

        #expect(model.programmedLevel?.cutFrequency == 650)
        #expect(model.programmedLevel?.feedDB == CrossfeedLevel.feedRange.upperBound)
    }

    /// Retuning does not re-wire the graph, so the pane may call the seam on every
    /// slider tick — but an UNCHANGED write must still cost nothing.
    @Test("a same-value write reaches neither the engine nor the store")
    func sameValueWriteIsIgnored() {
        let harness = CrossfeedFixtures.Harness("sameValue")
        defer { harness.tearDown() }
        let model = harness.model(started: true)
        model.preferences.isEnabled = true
        let requestsAfterEnable = harness.engine.requestedCrossfeedLevels.count

        model.preferences.isEnabled = true

        #expect(harness.engine.requestedCrossfeedLevels.count == requestsAfterEnable)
    }

    @Test("every distinct slider tick is programmed")
    func everyDistinctTickIsProgrammed() {
        let harness = CrossfeedFixtures.Harness("drag")
        defer { harness.tearDown() }
        let model = harness.model(started: true)
        model.preferences = CrossfeedPreferences(isEnabled: true, preset: .custom)
        let baseline = harness.engine.requestedCrossfeedLevels.count

        for frequency in stride(from: 400.0, through: 440.0, by: 10.0) {
            model.preferences.customCutFrequency = frequency
        }

        #expect(harness.engine.requestedCrossfeedLevels.count == baseline + 5)
        #expect(harness.engine.crossfeedLevel?.cutFrequency == 440)
    }
}

// MARK: - Persistence discipline

@MainActor
@Suite("Crossfeed persistence discipline")
struct CrossfeedSettingsModelPersistenceTests {
    /// `start()` ADOPTS what was already stored. A test asserting it left the store
    /// untouched is asserting the contract, not an accident.
    @Test("start() programmes the engine without writing anything back")
    func startDoesNotPersist() {
        let harness = CrossfeedFixtures.Harness("startNoWrite")
        defer { harness.tearDown() }

        _ = harness.model(started: true)

        #expect(harness.defaults.object(forKey: AppSettingsKeys.crossfeedEnabled) == nil)
        #expect(harness.defaults.object(forKey: AppSettingsKeys.crossfeedPreset) == nil)
        #expect(harness.defaults.object(forKey: AppSettingsKeys.crossfeedCustomCutFrequency) == nil)
    }

    @Test("a mutation persists, so a relaunch restores it")
    func mutationPersistsAcrossModels() {
        let harness = CrossfeedFixtures.Harness("relaunch")
        defer { harness.tearDown() }
        let first = harness.model(started: true)

        first.preferences = CrossfeedPreferences(
            isEnabled: true,
            preset: .custom,
            customCutFrequency: 900,
            customFeedDB: 6
        )
        let second = harness.model()

        #expect(second.preferences.isEnabled)
        #expect(second.preferences.preset == .custom)
        #expect(second.preferences.customLevel == CrossfeedLevel(cutFrequency: 900, feedDB: 6))
    }

    @Test("a relaunch re-inserts the stage the listener left switched on")
    func startAdoptsAStoredEnabledStage() {
        let harness = CrossfeedFixtures.Harness("relaunchStart")
        defer { harness.tearDown() }
        CrossfeedPreferences(isEnabled: true, preset: .jmeier).persist(to: harness.defaults)

        _ = harness.model(started: true)

        #expect(harness.engine.crossfeedLevel == CrossfeedLevel.jmeier)
    }
}
