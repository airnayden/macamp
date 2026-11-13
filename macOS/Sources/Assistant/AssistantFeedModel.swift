// AssistantFeedModel — what the Assistant pane's suggestion feed shows.
//
// A projection, not a store: everything here is re-derived on appear and NEVER
// persisted, the same discipline `KaraokeReadyStore` / `KaraokeQueueStore` follow.
//
// The two sources are deliberately different in kind. Auto-mixes are MATERIALISED
// rows (`generatedPlaylist` + an ordinary `playlist`), so the feed lists them and a
// card opens the real playlist. Hygiene findings are computed on the fly and are
// shown only as a COUNT — the card is a teaser, and turning a finding into a change
// stays with the proposal flow, which never writes without an explicit review.
//
// Nothing here runs on a timer. `refreshIfStale` is the assistant-appear seam: it is
// TTL-gated and idempotent, returns immediately when everything is fresh, and is the
// only reason a visit to this pane can write anything at all.
import Foundation
import Observation
import Services

@MainActor
@Observable
final class AssistantFeedModel {
    /// Ceiling on the hygiene pass this card summarises. The pass caps itself at
    /// `LibraryHygieneService.maxFindings`; asking for that much makes the number on
    /// the card the same number the proposal flow would work from.
    static let hygieneLimit = LibraryHygieneService.maxFindings

    private(set) var autoMixes: [GeneratedPlaylistSummary] = []
    private(set) var rediscovery: [GeneratedPlaylistSummary] = []

    /// Findings the hygiene pass counted, or `nil` when it did not run (bundle off,
    /// or the pass failed). `0` is a real answer — "your library looks tidy" — and
    /// must stay distinguishable from "not measured".
    private(set) var hygieneFindingCount: Int?

    private(set) var isLoading = false

    var isEmpty: Bool {
        autoMixes.isEmpty && rediscovery.isEmpty && hygieneFindingCount == nil
    }

    func load(
        profileId: Int64,
        generated: (any GeneratedPlaylistProviding)?,
        hygiene: (any LibraryHygieneProviding)?
    ) async {
        isLoading = true
        defer { isLoading = false }
        await loadGeneratedPlaylists(profileId: profileId, generated: generated)
        await loadHygieneCount(profileId: profileId, hygiene: hygiene)
    }
}

// MARK: - Sources

private extension AssistantFeedModel {
    func loadGeneratedPlaylists(profileId: Int64, generated: (any GeneratedPlaylistProviding)?) async {
        guard let generated else {
            assign(autoMixes: [], rediscovery: [])
            return
        }
        _ = try? await generated.refreshIfStale(profileId: profileId)
        let summaries = await (try? generated.generatedPlaylists(profileId: profileId)) ?? []
        assign(
            autoMixes: summaries.filter { $0.kind != .rediscovery },
            rediscovery: summaries.filter { $0.kind == .rediscovery }
        )
    }

    func loadHygieneCount(profileId: Int64, hygiene: (any LibraryHygieneProviding)?) async {
        guard let hygiene else {
            set(hygieneFindingCount: nil)
            return
        }
        let findings = try? await hygiene.findings(profileId: profileId, limit: Self.hygieneLimit)
        set(hygieneFindingCount: findings?.count)
    }

    /// Observation notifies on a same-value write, so every mirror is equality-guarded
    /// (the macOS shell's measured `@Observable` rule) — a re-appear that finds the
    /// same feed invalidates no view.
    func assign(
        autoMixes newAutoMixes: [GeneratedPlaylistSummary],
        rediscovery newRediscovery: [GeneratedPlaylistSummary]
    ) {
        if autoMixes != newAutoMixes { autoMixes = newAutoMixes }
        if rediscovery != newRediscovery { rediscovery = newRediscovery }
    }

    func set(hygieneFindingCount newCount: Int?) {
        if hygieneFindingCount != newCount { hygieneFindingCount = newCount }
    }
}
