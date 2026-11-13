// IntelligencePaneSettingsTests — the Intelligence pane's six switches are six preferences.
//
// `AIGatingWiringTests` proves the graph is built or not built from the master
// switch, and that the switch itself round-trips. What it does not pin is the
// thing a six-row settings pane is most likely to get wrong: two rows writing the
// same stored property, or `isEnabled(_:)` reading the neighbouring one. Both
// would look correct in the UI and silently disable the wrong feature, so each
// bundle is asserted to own its key ALONE — flipping it must leave the other five
// untouched across a reload.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Intelligence pane settings")
@MainActor
struct IntelligencePaneSettingsTests {
    @Test("each feature switch owns its own key", arguments: AIFeatureBundle.allCases)
    func eachBundleRoundTripsIndependently(bundle: AIFeatureBundle) {
        let store = Self.store(named: "\(Self.suitePrefix).\(bundle.rawValue)")
        let settings = AppSettings(defaults: store)
        #expect(settings.isEnabled(bundle))

        Self.setEnabled(false, for: bundle, in: settings)

        let reloaded = AppSettings(defaults: store)
        #expect(!reloaded.isEnabled(bundle))
        for other in AIFeatureBundle.allCases where other != bundle {
            #expect(reloaded.isEnabled(other), "\(other.rawValue) should be untouched by \(bundle.rawValue)")
        }
    }

    @Test("the master switch masks the bundles without erasing them")
    func theTopLevelSwitchIsNonDestructive() {
        let store = Self.store(named: "\(Self.suitePrefix).masking")
        let settings = AppSettings(defaults: store)
        settings.hygieneEnabled = false

        settings.intelligenceEnabled = false
        #expect(AIFeatureBundle.allCases.allSatisfy { !settings.isEnabled($0) })

        settings.intelligenceEnabled = true
        #expect(!settings.isEnabled(.hygiene))
        #expect(settings.isEnabled(.autoMixes))
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.intelligencePane"

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }

    /// Mirrors the pane's own `binding(for:)` switch, so a mapping that drifts on
    /// one side shows up as a failure here.
    private static func setEnabled(_ enabled: Bool, for bundle: AIFeatureBundle, in settings: AppSettings) {
        switch bundle {
        case .nlCreation: settings.nlCreationEnabled = enabled
        case .autoMixes: settings.autoMixesEnabled = enabled
        case .organization: settings.organizationEnabled = enabled
        case .rediscovery: settings.rediscoveryEnabled = enabled
        case .insights: settings.insightsEnabled = enabled
        case .hygiene: settings.hygieneEnabled = enabled
        }
    }
}
