// FakeAISettings — every AI switch, all ON by default.
//
// The defaults mirror the shipped product decision (the master toggle ships ON
// with the free heuristic bundles active), so a test that does not care about
// gating gets production behaviour for free, and a test that DOES care flips
// exactly one flag and asserts the service went silent.
//
// A `@MainActor final class` because ``AISettingsProviding`` is `@MainActor` —
// the same reason ``FakeAudioAnalysisService`` needs no lock.
import Services

/// A settable ``AISettingsProviding`` for hermetic tests and previews.
@MainActor
public final class FakeAISettings: AISettingsProviding {
    public var intelligenceEnabled = true
    public var nlCreationEnabled = true
    public var autoMixesEnabled = true
    public var organizationEnabled = true
    public var rediscoveryEnabled = true
    public var insightsEnabled = true
    public var hygieneEnabled = true

    public init() {}

    /// Sets every switch, the master toggle included.
    public func setAll(_ enabled: Bool) {
        intelligenceEnabled = enabled
        nlCreationEnabled = enabled
        autoMixesEnabled = enabled
        organizationEnabled = enabled
        rediscoveryEnabled = enabled
        insightsEnabled = enabled
        hygieneEnabled = enabled
    }
}
