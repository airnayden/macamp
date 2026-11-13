// StatsInsightsModel — the narrative behind the Stats insights card, and the rule
// that it is written ONLY when the listener asks.
//
// ── WHY THIS IS A MODEL AND NOT `@State` IN THE VIEW ──────────────────────────
//
// The whole contract of this surface is a NEGATIVE one — "generating does not
// happen" — and a negative is only provable by counting calls on the seam. Keeping
// the latch and the generation counter in an `@Observable` model lets
// `StatsInsightsModelTests` drive a spy `InsightNarrating` and assert the exact
// call count; the same logic written as `@State` inside a `View` would be
// assertable only through the UI, where "it did not regenerate" is indistinguishable
// from "it regenerated identically".
//
// ── THE TWO ENTRY POINTS ──────────────────────────────────────────────────────
//
//   * ``loadIfNeeded(for:)`` — the card's first appearance. Latched, so a second
//     appearance, a re-render, or a window switch costs nothing.
//   * ``refresh(for:)`` — the refresh button, and NOTHING else. Always regenerates.
//
// Switching the period therefore leaves the narrative describing the PREVIOUS
// window until the listener refreshes. That is deliberate: narration is the only
// facet of this page that is not free (it can reach an on-device model), so it is
// the only one that does not follow the filter automatically.
//
// ── FAILURE IS INVISIBLE ──────────────────────────────────────────────────────
//
// The injected narrator is always a `FallbackInsightNarrating`, which answers from
// deterministic templates whenever the model tier refuses, throttles, or does not
// exist. This type adds `try?` on top only so a cancellation cannot leave the
// spinner up — there is no error state to render because there is no error a
// listener could act on.
import Foundation
import Observation
import Services

/// The narrative state of one Stats insights card.
@MainActor
@Observable
final class StatsInsightsModel {
    /// The generated narrative, or `nil` when none has been produced yet.
    ///
    /// GENERATED CONTENT IS DATA: rendered `Text(verbatim:)`, never through a String
    /// Catalog, whether it came from the model tier or the template tier.
    private(set) var narrative: String?

    /// `true` while a narrative is being written.
    private(set) var isGenerating = false

    @ObservationIgnored private let narrator: any InsightNarrating
    @ObservationIgnored private let locale: Locale

    /// Whether a narrative has ever been produced for this card. Only ever set on a
    /// pass that actually had a digest to narrate, so a card that appears before the
    /// stats load still narrates once the digest arrives.
    @ObservationIgnored private var hasNarrated = false

    /// Bumped per pass so a slow generation cannot overwrite a newer one's result.
    @ObservationIgnored private var generation = 0

    init(narrator: any InsightNarrating, locale: Locale = .autoupdatingCurrent) {
        self.narrator = narrator
        self.locale = locale
    }

    /// Writes the first narrative for `digest`, and nothing thereafter.
    func loadIfNeeded(for digest: ListeningWindowDigest?) async {
        guard !hasNarrated else { return }
        await narrate(digest)
    }

    /// Rewrites the narrative for `digest`. The refresh button's action.
    func refresh(for digest: ListeningWindowDigest?) async {
        await narrate(digest)
    }

    private func narrate(_ digest: ListeningWindowDigest?) async {
        guard let digest else {
            narrative = nil
            return
        }
        hasNarrated = true
        generation &+= 1
        let token = generation
        isGenerating = true
        let result = try? await narrator.narrate(
            InsightNarrationContext.projecting(digest),
            locale: locale
        )
        guard token == generation else { return }
        narrative = result?.narrative
        isGenerating = false
    }
}
