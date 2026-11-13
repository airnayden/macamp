// AppEnvironment+AI+Narrator — which tier writes the listening narrative.
//
// Moved VERBATIM out of `AppEnvironment+AI.swift` (a pure relocation, no code change)
// so that file keeps headroom under the SwiftLint `file_length` ceiling for the two
// `handleAIGraphRebuilt()` calls `rebuildAI`/`rescopeAI` now end with. Both functions
// keep their names, their access levels and their call sites.
//
// They belong together and alone: `modelInsightNarrator()` is `private`, so it and its
// only caller have to travel as a pair — Swift scopes `private` to the declaring file.
import Foundation
import Services

// MARK: - Insight narration

extension AppEnvironment {
    /// The listening-insights narrator: the best available tier wrapped in the
    /// template tier.
    ///
    /// The wrap is what makes an unavailable model INVISIBLE. `FallbackInsightNarrating`
    /// swallows every failure except cancellation and answers from
    /// `AssistantNarrationTemplates`, so a refusal, a throttle, an ineligible device, a
    /// pre-26 OS and an unreachable provider all produce an ordinary narrative rather
    /// than an error the listener has to read. That silence is the approved product
    /// default for this surface.
    ///
    /// Capability is therefore decided PER REQUEST, by the session throwing, rather than
    /// by probing `SystemLanguageModel` here — the same trade `makeAssistantBackends`
    /// already makes for `FMPlaylistNaming`. Probing eagerly would put a system query on
    /// the launch path and would freeze the tier choice at launch, so a model that
    /// finishes preparing mid-session would never be used.
    ///
    /// - Parameter connector: the connector tier, when one is selected. It REPLACES
    ///   the FoundationModels tier rather than layering above it: `FallbackInsightNarrating`
    ///   takes one primary, and the listener's explicit provider choice is the one
    ///   that should be honoured.
    static func makeInsightNarrator(connector: (any InsightNarrating)? = nil) -> any InsightNarrating {
        FallbackInsightNarrating(primary: connector ?? modelInsightNarrator())
    }

    /// The FoundationModels tier, or `nil` when it cannot be referenced at all — the
    /// SDK lacks the framework, or the running OS predates macOS 26 / iOS 26.
    private static func modelInsightNarrator() -> (any InsightNarrating)? {
        #if DEBUG
            // XCUITest runs on fakes throughout; a real model round-trip would make the
            // narrative both non-deterministic and slow, so under the hermetic seam the
            // template tier IS the whole ladder.
            if ProcessInfo.processInfo.environment["UITEST_SEED_PATH"] != nil { return nil }
        #endif
        // DEPRECATED: Apple Intelligence is retired, so the template tier answers when no
        // connector is selected. Remove `FMInsightNarrator` with `AppleIntelligenceRetirement`.
        if AppleIntelligenceRetirement.isRetired { return nil }
        #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                return FMInsightNarrator()
            }
        #endif
        return nil
    }
}
