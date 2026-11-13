import AudioEngine
import Foundation
import Persistence
import Testing
@testable import ViewModels

// ParametricEQPresetBankTests — the saved parametric preset bank.
//
// Named `…PresetBankTests` rather than `…PresetTests` so it cannot be confused
// with `PersistenceTests.ParametricEQPresetTests`, which covers the store itself.

@MainActor
struct ParametricEQPresetBankTests {
    @Test("saving round-trips the bank and the trim through the store")
    func savePresetRoundTrips() throws {
        let store = FakeParametricEQPresetStore()
        let model = ParametricEQViewModel(engine: FakePlaybackEngine(), presetStore: store)
        model.addFilter(ParametricFilter(type: .peaking, frequency: 880, gainDB: 3.5, qFactor: 2.25))
        model.setPreamp(-4.5)

        model.savePreset(named: "Mine")

        #expect(model.lastFailure == nil)
        #expect(model.selectedPresetName == "Mine")
        let row = try #require(model.presets.first { $0.name == "Mine" })
        #expect(row.isReadable)
        #expect(row.filters == model.filters)
        #expect(row.preampDB == -4.5)
    }

    @Test("a zero trim is stored as 'no trim recorded', matching EQPreset")
    func zeroPreampIsStoredAsNil() throws {
        let store = FakeParametricEQPresetStore()
        let model = ParametricEQViewModel(engine: FakePlaybackEngine(), presetStore: store)
        model.addFilter()
        model.savePreset(named: "Flat bank")
        let stored = try #require(try store.loadAll().first)
        #expect(stored.preamp == nil)
    }

    @Test("applying a preset installs it and activates parametric mode")
    func applyPresetInstallsTheBank() throws {
        let filters = ParametricFixtures.filters(count: 3)
        let preset = try ParametricEQPreset(name: "Bank", filters: filters, preamp: -2)
        let (model, engine) = makeModel(presets: [preset])
        model.loadPresets()

        model.applyPreset(named: "Bank")

        #expect(model.mode == .parametric)
        #expect(model.filters == filters)
        #expect(model.preampDB == -2)
        #expect(model.selectedPresetName == "Bank")
        #expect(engine.parametricConfiguration?.filters == filters)
    }

    @Test("editing after applying clears the preset selection")
    func editingClearsTheSelection() throws {
        let preset = try ParametricEQPreset(name: "Bank", filters: ParametricFixtures.filters(count: 2))
        let (model, _) = makeModel(presets: [preset])
        model.loadPresets()
        model.applyPreset(named: "Bank")
        #expect(model.selectedPresetName == "Bank")

        model.setPreamp(-1)
        #expect(model.selectedPresetName == nil)
    }

    /// THE STRUCTURAL FAILURE PATH. `loadAll()` never decodes `filtersJson`, so a
    /// corrupt row must still render — with an "unreadable" badge and a delete
    /// affordance — rather than disappearing or emptying the whole list.
    @Test("an unreadable preset keeps its row, refuses to apply, and stays deletable")
    func unreadablePresetKeepsItsRow() throws {
        let good = try ParametricEQPreset(name: "Good", filters: ParametricFixtures.filters(count: 2))
        let broken = ParametricEQPreset(name: "Broken", filtersJson: "{not-an-array", preamp: -1)
        let (model, engine) = makeModel(presets: [good, broken])

        model.loadPresets()

        #expect(model.presets.count == 2)
        let brokenRow = try #require(model.presets.first { $0.name == "Broken" })
        #expect(!brokenRow.isReadable)
        #expect(brokenRow.filterCount == 0)
        #expect(brokenRow.configuration == nil)
        #expect(try #require(model.presets.first { $0.name == "Good" }).isReadable)

        model.applyPreset(named: "Broken")
        #expect(model.lastFailure == .presetUnreadable(name: "Broken"))
        #expect(model.filters.isEmpty)
        #expect(engine.requestedParametricConfigurations.isEmpty)

        model.deletePreset(named: "Broken")
        #expect(model.presets.map(\.name) == ["Good"])
    }

    /// A hand-authored 17-filter row can reach the store even though the editor and
    /// the parser both refuse one. It must be refused BEFORE the engine is touched.
    @Test("a 17-filter preset is refused before it reaches the engine")
    func overCapacityPresetIsRefusedBeforeTheEngine() throws {
        let maximum = ParametricEQConfiguration.maximumFilterCount
        let preset = try ParametricEQPreset(
            name: "Too many",
            filters: ParametricFixtures.filters(count: maximum + 1)
        )
        let (model, engine) = makeModel(presets: [preset])
        model.loadPresets()
        model.setMode(.parametric)

        model.applyPreset(named: "Too many")

        #expect(model.lastFailure == .capacityExceeded(count: maximum + 1, maximum: maximum))
        #expect(model.filters.isEmpty)
        #expect(model.selectedPresetName == nil)
        // `setMode` installed the empty bank; the 17-filter one never got past the
        // capacity check, so the engine's recorded history holds only that one.
        #expect(engine.parametricConfiguration == .bypass)
        let requested = engine.requestedParametricConfigurations.compactMap(\.self)
        #expect(requested == [.bypass])
    }

    @Test("deleting the applied preset clears the selection but keeps the bank")
    func deletingTheAppliedPresetKeepsTheBank() throws {
        let filters = ParametricFixtures.filters(count: 2)
        let preset = try ParametricEQPreset(name: "Bank", filters: filters)
        let (model, _) = makeModel(presets: [preset])
        model.loadPresets()
        model.applyPreset(named: "Bank")

        model.deletePreset(named: "Bank")

        #expect(model.presets.isEmpty)
        #expect(model.selectedPresetName == nil)
        #expect(model.filters == filters)
    }
}
