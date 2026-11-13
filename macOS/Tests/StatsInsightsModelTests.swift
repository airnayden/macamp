// StatsInsightsModelTests — the Stats insights card narrates ONLY when asked.
//
// The contract under test is a negative one, so every case here counts calls on the
// `InsightNarrating` seam rather than inspecting rendered text: "the narrative did
// not regenerate" is indistinguishable from "it regenerated identically" at the UI
// layer, which is precisely why the latch lives in a model instead of in `@State`.
//
// The template cases inject the REAL `FallbackInsightNarrating` rather than a canned
// fake, because the behaviour being asserted — a failing model tier degrades to a
// deterministic narrative with nothing surfaced — belongs to that wrapper. A fake
// that simply returned template text would assert the test's own arithmetic.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Stats insights card narration")
@MainActor
struct StatsInsightsModelTests {
    @Test("the first appearance narrates once, and later appearances do not")
    func firstLoadNarratesExactlyOnce() async {
        let spy = SpyInsightNarrator()
        let model = StatsInsightsModel(narrator: spy, locale: Self.locale)

        await model.loadIfNeeded(for: Self.digest(.last7Days, plays: 7))
        await model.loadIfNeeded(for: Self.digest(.last7Days, plays: 7))

        #expect(await spy.callCount == 1)
        #expect(model.narrative == "7 plays over last7Days")
    }

    @Test("switching the period alone leaves the previous narrative in place")
    func windowSwitchDoesNotRegenerate() async {
        let spy = SpyInsightNarrator()
        let model = StatsInsightsModel(narrator: spy, locale: Self.locale)
        await model.loadIfNeeded(for: Self.digest(.last7Days, plays: 7))

        await model.loadIfNeeded(for: Self.digest(.last30Days, plays: 30))

        #expect(await spy.callCount == 1)
        #expect(model.narrative == "7 plays over last7Days")
    }

    @Test("refreshing after a period switch reports the new period's figures")
    func refreshAfterWindowSwitchUpdatesTheNarrative() async {
        let spy = SpyInsightNarrator()
        let model = StatsInsightsModel(narrator: spy, locale: Self.locale)
        await model.loadIfNeeded(for: Self.digest(.last7Days, plays: 7))

        await model.refresh(for: Self.digest(.last30Days, plays: 30))

        #expect(await spy.callCount == 2)
        #expect(model.narrative == "30 plays over last30Days")
    }

    @Test("every refresh regenerates, however many times it is pressed")
    func refreshAlwaysRegenerates() async {
        let spy = SpyInsightNarrator()
        let model = StatsInsightsModel(narrator: spy, locale: Self.locale)
        let digest = Self.digest(.allTime, plays: 1)

        await model.loadIfNeeded(for: digest)
        await model.refresh(for: digest)
        await model.refresh(for: digest)

        #expect(await spy.callCount == 3)
    }

    @Test("a card that appears before the digest still narrates once it arrives")
    func aMissingDigestDoesNotLatchTheCardShut() async {
        let spy = SpyInsightNarrator()
        let model = StatsInsightsModel(narrator: spy, locale: Self.locale)

        await model.loadIfNeeded(for: nil)
        #expect(await spy.callCount == 0)
        #expect(model.narrative == nil)

        await model.loadIfNeeded(for: Self.digest(.last30Days, plays: 3))

        #expect(await spy.callCount == 1)
    }

    @Test("a profile with no plays gets the localized empty narrative, not a crash")
    func emptyProfileFallsBackToTheLocalizedTemplate() async {
        let model = StatsInsightsModel(
            narrator: FallbackInsightNarrating(primary: nil),
            locale: Self.locale
        )
        let digest = Self.digest(.last7Days, plays: 0)

        await model.loadIfNeeded(for: digest)

        #expect(model.narrative == Self.templateNarrative(for: digest))
        #expect(model.narrative?.isEmpty == false)
    }

    @Test("an unavailable model tier degrades to the template with nothing surfaced")
    func aFailingModelTierIsSilent() async {
        let model = StatsInsightsModel(
            narrator: FallbackInsightNarrating(primary: FailingInsightNarrator()),
            locale: Self.locale
        )
        let digest = Self.digest(.last30Days, plays: 12)

        await model.loadIfNeeded(for: digest)

        #expect(model.narrative == Self.templateNarrative(for: digest))
        #expect(!model.isGenerating)
    }

    // MARK: Fixtures

    /// Fixed so the template comparisons resolve the same catalog entries the
    /// production path would, without depending on the host's language.
    private static let locale = Locale(identifier: "en_US")

    private static func digest(_ window: ListeningWindowKind, plays: Int) -> ListeningWindowDigest {
        ListeningWindowDigest(window: window, totalPlays: plays)
    }

    private static func templateNarrative(for digest: ListeningWindowDigest) -> String {
        AssistantNarrationTemplates.fallbackNarrative(
            for: InsightNarrationContext.projecting(digest),
            locale: locale
        ).narrative
    }
}

// MARK: - Doubles

/// Counts narration calls and echoes the projection back, so a stale narrative is
/// visible as WHICH window it describes rather than only as a call count.
private actor SpyInsightNarrator: InsightNarrating {
    private(set) var callCount = 0

    func narrate(
        _ context: InsightNarrationContext,
        locale _: Locale
    ) async throws -> InsightNarrationResult {
        callCount += 1
        return InsightNarrationResult(
            narrative: "\(context.totalPlays) plays over \(context.window.rawValue)"
        )
    }
}

/// Stands in for every reason the model tier can fail — refusal, throttling, an
/// ineligible device — all of which `FallbackInsightNarrating` must absorb.
private struct FailingInsightNarrator: InsightNarrating {
    func narrate(
        _: InsightNarrationContext,
        locale _: Locale
    ) async throws -> InsightNarrationResult {
        throw AssistantFailure.unknown
    }
}
