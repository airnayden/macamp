// DownloadsViewModel+History — the ADVISORY "you have had some of these before" hint.
//
// ── WHY THIS IS A SEPARATE METHOD AND NOT PART OF THE PASTE ──────────────────
//
// The hint is a sentence, not a decision. It must never make a paste slower, never
// change what the queue accepted, and never skip a link. The cheapest way to guarantee
// all three is structural rather than procedural: this extension has no reference to
// `DownloadQueueing` at all, so no code path here CAN reach an enqueue, and the caller
// invokes it only once `enqueue(urls:)` has already returned its finalised
// `EnqueueOutcome`. `DownloadPasteResult` and `DownloadPasteReport` are likewise
// untouched — the count travels back separately, so a paste that never asks for the
// hint produces byte-identical values to one that does.
//
// ── ONE STATEMENT, AND A CALL-SITE CEILING ON TOP OF THE REPOSITORY'S ────────
//
// ``DownloadHistoryRepositoryProviding/knownVideoIDs(in:)`` is one bounded `IN (…)`
// and carries its own 500-id ceiling. This hint asks about far fewer:
// ``DownloadsViewModel/previouslyDownloadedLookupLimit`` ids, deduplicated in PASTE
// order, so a 500-video playlist paste costs exactly the same single small statement a
// three-link paste does. Per-id lookups are not an implementation this can degrade into
// — there is one call, and it takes an array.
//
// ── A FAILURE HERE IS SILENCE, NEVER AN ERROR ────────────────────────────────
//
// A wedged database must not turn a working paste into a visible fault. A throw is
// absorbed into "0", which renders as no line at all, and the paste's own success is
// entirely independent of this lookup ever running.
//
// This file imports only Foundation + Persistence + Services; it MUST NOT import AppKit
// or UIKit (PlayerCore portability invariant), nor URLSession or Process (the
// downloader boundary gate — `PlayerCore/Sources/ViewModels` is scanned wholesale).
import Foundation
import Persistence
import Services

public extension DownloadsViewModel {
    /// The most canonical ids one advisory lookup asks about.
    ///
    /// Well inside ``DownloadHistoryRepository/videoIDLookupLimit``: the repository's
    /// bound exists to keep a single statement's bound-variable list sane, while this
    /// one is a product decision about how much a one-sentence hint may cost. A paste
    /// larger than this still gets a hint — about its first ids — because a partial
    /// honest answer beats a lookup that scales with the paste.
    static var previouslyDownloadedLookupLimit: Int {
        50
    }

    /// How many of `urls` name a video this listener has downloaded before.
    ///
    /// ADVISORY ONLY. Answers `0` when there is no history to consult, when the paste
    /// named no video, and when the lookup fails — all three are "say nothing", and the
    /// caller renders no line for a zero. Nothing here enqueues, dedups, or gates.
    ///
    /// Call it AFTER the paste's own `enqueue(urls:)` has returned.
    func previouslyDownloadedCount(in urls: [URL]) async -> Int {
        guard let history else { return 0 }
        let ids = Self.advisoryVideoIDs(in: urls)
        guard !ids.isEmpty else { return 0 }
        // Detached at `.utility` on purpose: the hint is the lowest-priority work in the
        // app and must never contend with a live progress bar, so both the await and the
        // set it resolves stay off the main actor until the count comes back.
        let known = await Task.detached(priority: .utility) {
            try? await history.knownVideoIDs(in: ids)
        }.value
        return known?.count ?? 0
    }
}

extension DownloadsViewModel {
    /// The first ``previouslyDownloadedLookupLimit`` distinct canonical ids `urls`
    /// names, in paste order.
    ///
    /// Deduplicating in caller order — rather than `Set(…).prefix(n)` — is what makes
    /// *which* ids a truncated paste asks about deterministic, matching the ordering
    /// ``DownloadHistoryRepository`` applies to its own ceiling. Playlist links name no
    /// video and simply contribute nothing.
    static func advisoryVideoIDs(in urls: [URL]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        kept.reserveCapacity(min(urls.count, previouslyDownloadedLookupLimit))
        for url in urls {
            guard let id = YouTubeURLNormalizer.canonicalVideoID(from: url),
                  seen.insert(id).inserted
            else {
                continue
            }
            kept.append(id)
            if kept.count == previouslyDownloadedLookupLimit { break }
        }
        return kept
    }
}
