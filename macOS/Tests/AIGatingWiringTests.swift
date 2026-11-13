// AIGatingWiringTests — the composition root really is gated on the toggle.
//
// `AIGatingTests` (PlayerCore) proves each AI SERVICE goes silent when its switch
// is off. What it cannot prove is that the shell ever declines to BUILD them — and
// a graph that is constructed regardless is exactly the failure this todo exists to
// prevent: services alive, observations armed, work scheduled, with the listener
// believing the feature is off. This suite closes that from the shell side, and
// lives in the app test target because `AppEnvironment` is not part of the package.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("AI composition gating")
@MainActor
struct AIGatingWiringTests {
    @Test("the master toggle off exposes no AI services at all")
    func intelligenceOffExposesNoServices() {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = false
        let environment = AppEnvironment.preview()

        environment.connectAI(settings: settings)

        #expect(environment.intelligence == nil)
    }

    @Test("the master toggle on builds the whole graph")
    func intelligenceOnBuildsTheGraph() {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()

        environment.connectAI(settings: settings)

        #expect(environment.intelligence != nil)
        #expect(environment.intelligence?.proposals.isEmpty == true)
    }

    @Test("switching the toggle on rebuilds the graph without a relaunch")
    func togglingOnRebuildsLive() async {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = false
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        #expect(environment.intelligence == nil)

        settings.intelligenceEnabled = true

        await Self.settle()
        #expect(environment.intelligence != nil)
    }

    @Test("switching the toggle off tears the graph down without a relaunch")
    func togglingOffTearsDownLive() async {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        #expect(environment.intelligence != nil)

        settings.intelligenceEnabled = false

        await Self.settle()
        #expect(environment.intelligence == nil)
    }

    @Test("the observation re-arms, so the toggle keeps working after the first flip")
    func theObservationSurvivesRepeatedFlips() async {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)

        var observed: [Bool] = []
        for enabled in [false, true, false, true] {
            settings.intelligenceEnabled = enabled
            await Self.settle()
            observed.append(environment.intelligence != nil)
        }

        #expect(observed == [false, true, false, true])
    }

    @Test("the AI toggles ship on and round-trip through UserDefaults")
    func togglesDefaultOnAndPersist() {
        let name = "\(Self.suitePrefix).\(#function)"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)

        #expect(settings.intelligenceEnabled)
        #expect(AIFeatureBundle.allCases.allSatisfy { settings.isEnabled($0) })

        settings.intelligenceEnabled = false
        settings.hygieneEnabled = false

        let reloaded = AppSettings(defaults: store)
        #expect(!reloaded.intelligenceEnabled)
        #expect(!reloaded.hygieneEnabled)
        #expect(reloaded.autoMixesEnabled)
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.ai"

    /// A settings store on a volatile, per-test suite so nothing leaks into the
    /// developer's real preferences or between cases.
    private static func settings(_ function: String) -> AppSettings {
        AppSettings(defaults: store(named: "\(suitePrefix).\(function)"))
    }

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }

    /// Lets the observation's main-actor hop run. `withObservationTracking` reports
    /// a change BEFORE the write lands, so the rebuild is deliberately deferred to a
    /// `Task`; yielding is what makes that deterministic without a sleep.
    private static func settle() async {
        for _ in 0 ..< 8 {
            await Task.yield()
        }
    }
}
