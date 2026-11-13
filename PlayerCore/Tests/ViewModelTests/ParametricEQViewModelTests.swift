import AudioEngine
import Foundation
import Persistence
import Testing
@testable import ViewModels

// ParametricEQViewModelTests — mode selection, band editing and AutoEq import.
//
// The saved-preset bank is covered by `ParametricEQPresetBankTests`; the shared
// fixtures and model factory live in `ParametricEQTestSupport`.

// MARK: - Mode

@MainActor
struct ParametricEQModeTests {
    @Test("a fresh model is in graphic mode and has never touched the parametric stage")
    func freshModelIsGraphicAndInert() {
        let (model, engine) = makeModel()
        #expect(model.mode == .graphic)
        #expect(model.filters.isEmpty)
        #expect(engine.requestedParametricConfigurations.isEmpty)
    }

    @Test("switching to parametric installs the bank, switching back DETACHES it")
    func switchingToGraphicClearsTheConfiguration() {
        let (model, engine) = makeModel()
        model.addFilter()
        model.setMode(.parametric)
        #expect(engine.parametricConfiguration?.filters.count == 1)

        model.setMode(.graphic)

        #expect(model.mode == .graphic)
        // `nil` DETACHES the node — it does not bypass sixteen bands.
        #expect(engine.requestedParametricConfigurations.last == .some(nil))
        #expect(engine.parametricConfiguration == nil)
        #expect(engine.gainComposer.parametricPreampDB == 0)
        // The bank itself survives, so flipping back restores it verbatim.
        #expect(model.filters.count == 1)
    }

    @Test("edits made in graphic mode never reach the engine")
    func graphicModeEditsAreNotPushed() {
        let (model, engine) = makeModel()
        model.addFilter()
        model.setPreamp(-3)
        #expect(model.filters.count == 1)
        #expect(engine.requestedParametricConfigurations.isEmpty)
    }

    @Test("edits made in parametric mode are pushed on every change")
    func parametricModeEditsArePushed() {
        let (model, engine) = makeModel()
        model.setMode(.parametric)
        model.addFilter()
        model.setPreamp(-3)
        #expect(engine.parametricConfiguration?.preampDB == -3)
        #expect(engine.gainComposer.parametricPreampDB == -3)
    }

    @Test("re-selecting the current mode is a no-op")
    func settingTheSameModeDoesNothing() {
        let (model, engine) = makeModel()
        model.setMode(.graphic)
        #expect(engine.requestedParametricConfigurations.isEmpty)
    }
}

// MARK: - Band editing

@MainActor
struct ParametricEQEditingTests {
    @Test("a new band is a neutral 1 kHz bell")
    func addedBandIsNeutral() {
        let (model, _) = makeModel()
        model.addFilter()
        #expect(model.filters == [ParametricEQViewModel.defaultFilter])
        #expect(model.filters[0].gainDB == 0)
    }

    @Test("adding past the node's capacity is refused BEFORE the engine is touched")
    func addRefusesPastTheCeiling() {
        let maximum = ParametricEQViewModel.maximumFilterCount
        let (model, engine) = makeModel()
        model.setMode(.parametric)
        for filter in ParametricFixtures.filters(count: maximum) {
            model.addFilter(filter)
        }
        #expect(model.filters.count == maximum)
        #expect(!model.canAddFilter)

        model.addFilter()

        #expect(model.filters.count == maximum)
        #expect(model.lastFailure == .capacityExceeded(count: maximum + 1, maximum: maximum))
        // The engine never saw a seventeenth filter — not even as a refused request.
        let requested = engine.requestedParametricConfigurations.compactMap(\.self)
        let overCapacity = requested.count(where: { $0.filters.count > maximum })
        #expect(overCapacity == 0)
    }

    @Test("removing and replacing bands keeps profile order")
    func removeAndReplacePreserveOrder() {
        let (model, _) = makeModel()
        for filter in ParametricFixtures.filters(count: 3) {
            model.addFilter(filter)
        }
        model.removeFilter(at: 1)
        #expect(model.filters.map(\.frequency) == [100, 300])

        let replacement = ParametricFilter(type: .highShelf, frequency: 9000, gainDB: -2, qFactor: 0.7)
        model.setFilter(replacement, at: 0)
        #expect(model.filters[0] == replacement)
        #expect(model.filters.map(\.frequency) == [9000, 300])
    }

    @Test("out-of-range edits are ignored")
    func outOfRangeEditsAreIgnored() {
        let (model, _) = makeModel()
        model.addFilter()
        model.removeFilter(at: 7)
        model.setFilter(ParametricEQViewModel.defaultFilter, at: -1)
        #expect(model.filters.count == 1)
    }

    @Test("the approximated-shelf notice tracks a live Q edit")
    func shelfApproximationTracksEdits() {
        let (model, _) = makeModel()
        model.addFilter(ParametricFilter(type: .lowShelf, frequency: 105, gainDB: 6, qFactor: 0.70))
        #expect(!model.hasApproximatedShelfSlope)

        model.setFilter(
            ParametricFilter(type: .lowShelf, frequency: 105, gainDB: 6, qFactor: 2.0),
            at: 0
        )
        #expect(model.hasApproximatedShelfSlope)
        #expect(model.approximatedShelfFilterIndices == [0])
    }

    @Test("reset empties the bank and the trim without leaving parametric mode")
    func resetClearsTheBank() {
        let (model, engine) = makeModel()
        model.setMode(.parametric)
        model.addFilter()
        model.setPreamp(-6)
        model.reset()
        #expect(model.filters.isEmpty)
        #expect(model.preampDB == 0)
        #expect(model.mode == .parametric)
        #expect(engine.gainComposer.parametricPreampDB == 0)
    }
}

// MARK: - AutoEq import

@MainActor
struct ParametricEQImportTests {
    @Test("the committed AutoEq profile imports, and its pre-amp reaches the composer")
    func importsTheCommittedProfile() {
        let (model, engine) = makeModel()
        model.setMode(.parametric)

        model.importProfile(from: ParametricFixtures.autoEqProfile)

        #expect(model.lastFailure == nil)
        #expect(model.filters.count == 10)
        #expect(model.filters[0] == ParametricFilter(
            type: .lowShelf, frequency: 105, gainDB: 6.4, qFactor: 0.70
        ))
        #expect(model.filters[5].type == .highShelf)
        #expect(model.preampDB == -6.1)
        #expect(model.lastImportedProfileName == "Sennheiser HD 650 ParametricEQ")

        // The bank reached the engine, and the `Preamp:` line reached the composer
        // — forgetting the second is exactly how an AutoEq import clips.
        #expect(engine.parametricConfiguration?.filters.count == 10)
        #expect(abs(engine.gainComposer.parametricPreampDB - -6.1) < 0.0001)
        // Both shelves are Q 0.70, inside the ±20% band, so nothing is flagged.
        #expect(!model.hasApproximatedShelfSlope)
    }

    @Test("importing while in graphic mode activates parametric mode")
    func importActivatesParametricMode() {
        let (model, engine) = makeModel()
        model.importProfile(from: ParametricFixtures.autoEqProfile)
        #expect(model.mode == .parametric)
        #expect(engine.parametricConfiguration != nil)
    }

    @Test("a malformed profile reports the parse error and leaves the bank alone")
    func malformedProfileLeavesTheConfigurationUnchanged() throws {
        let (model, engine) = makeModel()
        model.setMode(.parametric)
        model.addFilter()
        let before = model.configuration
        let pushesBefore = engine.requestedParametricConfigurations.count

        let url = try ParametricFixtures.temporaryProfile(
            "Preamp: -6.1 dB\nFilter 1: ON PK Fc banana Hz Gain 5.1 dB Q 1.42\n"
        )
        model.importProfile(from: url)

        #expect(model.configuration == before)
        #expect(engine.requestedParametricConfigurations.count == pushesBefore)
        #expect(model.lastImportedProfileName == nil)
        let failure = try #require(model.lastFailure)
        guard case let .profileInvalid(parseError) = failure else {
            Issue.record("expected a parse failure")
            return
        }
        #expect(parseError.lineNumber == 2)
    }

    @Test("an over-capacity profile is refused by the parser, not by the engine")
    func overCapacityProfileIsRefused() throws {
        let maximum = ParametricEQConfiguration.maximumFilterCount
        let lines = (1 ... maximum + 1).map {
            "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1.0 dB Q 1.00"
        }
        let url = try ParametricFixtures.temporaryProfile(lines.joined(separator: "\n") + "\n")
        let (model, engine) = makeModel()
        model.setMode(.parametric)

        model.importProfile(from: url)

        #expect(model.filters.isEmpty)
        #expect(model.lastFailure == .profileInvalid(
            .tooManyFilters(count: maximum + 1, maximum: maximum)
        ))
        // The engine still holds the empty bank `setMode` installed — the refused
        // profile never reached it, not even as a recorded request.
        #expect(engine.parametricConfiguration == .bypass)
        let requested = engine.requestedParametricConfigurations.compactMap(\.self)
        #expect(requested == [.bypass])
    }

    @Test("an unreadable file is reported as unreadable, not as a parse error")
    func unreadableFileIsReported() {
        let (model, _) = makeModel()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macamp-absent-\(UUID().uuidString).txt")
        model.importProfile(from: missing)
        #expect(model.lastFailure == .profileUnreadable(fileName: missing.lastPathComponent))
    }

    @Test("clearFailure dismisses the alert state")
    func clearFailureResets() {
        let (model, _) = makeModel()
        model.importProfile(from: URL(fileURLWithPath: "/nope/nothing.txt"))
        #expect(model.lastFailure != nil)
        model.clearFailure()
        #expect(model.lastFailure == nil)
    }
}
