// DownloadRowLeaf — one ACTIVE download row as its own observable object, so a
// progress tick invalidates exactly one progress bar and none of its siblings.
//
// ── WHY A PER-ROW OBJECT AND NOT A MAP ON THE STORE ──────────────────────────
//
// `@Observable` tracks dependencies at PROPERTY granularity. A `[UUID: DownloadState]`
// map on the store is ONE property, so a leaf view reading `store.states[myID]`
// registers a dependency on the WHOLE map — and the tick that advances row 1 then
// invalidates the bars of rows 2…N too. With four parallel transfers each reporting
// several samples a second that is the exact rule-3 cascade the leaf pattern exists to
// prevent (SKILL macOS UI perf rule 3), and it is invisible in a value test: every bar
// still shows the right number, it just redraws N times as often as it must.
//
// Giving each row its own object makes a tick a write to ONE object's ONE property,
// which only that row's own bar reads. ``KaraokeQueueStore/currentProgress`` is the
// shipped single-row precedent (one scalar per leaf); this is its N-row generalization.
//
// ── WHAT LIVES HERE AND WHAT DOES NOT ────────────────────────────────────────
//
// The descriptive fields (``title`` / ``uploader``) and the live ``state`` are SEPARATE
// observable properties on purpose: a row body that renders the title depends on the
// former only, so a progress tick does not re-evaluate it either. The raw
// ``DownloadItem`` is deliberately NOT stored — it carries its own `state` field, and
// folding the whole value in would make every snapshot's stale state churn the title's
// dependency for nothing.
//
// This file imports only Foundation + Observation + Services; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant), nor URLSession or Process (the
// downloader boundary gate — `PlayerCore/Sources/ViewModels` is scanned wholesale by
// `scripts/check-ai-network-boundary.sh`).
import Foundation
import Observation
import Services

/// One in-flight download row, observable on its own so a progress sample re-renders
/// that row's progress bar and nothing else.
///
/// Created and owned by ``DownloadQueueStore``, which reuses the same instance for as
/// long as the row stays active — so the live ``state`` survives the snapshots that
/// merely enrich the row's title, and a view holding the leaf keeps its identity.
@MainActor
@Observable
public final class DownloadRowLeaf {
    /// The enqueue's identity — stable for the row's whole lifetime, and the key the
    /// progress seam addresses it by. NOT the video id: the same video can be queued
    /// again after a cancel.
    public let id: UUID

    /// The 11-character canonical YouTube video id this row transfers.
    public let canonicalVideoID: String

    /// The best label available right now: the fetched title, else the canonical id.
    ///
    /// A plain `String` because every value it can hold is untranslatable content, so a
    /// call site renders it with `Text(verbatim:)`. Changes only when the metadata
    /// prefetch lands — never on a progress tick.
    public private(set) var title: String

    /// The channel name, `nil` until the metadata prefetch fills it.
    public private(set) var uploader: String?

    /// The poster frame's URL, `nil` until a metadata pass fills it.
    ///
    /// A URL, never bytes: fetching and caching the image belongs to the shell (a
    /// portable module has no image type), and a leaf that held pixels would put a
    /// download queue's worth of them in observable state.
    public private(set) var thumbnailURL: URL?

    /// The container this row was dequeued with, `nil` until the driver stamps it.
    ///
    /// Descriptive, not live: the driver stamps it once, before the transfer starts, and
    /// it never moves again — so a caption naming the container ("Converting to MP3…")
    /// can be read from the same leaf as the bar without a progress sample touching it.
    public private(set) var resolvedFormat: DownloadFormat?

    /// The row's LIVE lifecycle state — the ONE property a progress sample writes.
    ///
    /// Read it from a leaf view (a progress bar and its caption), never from a list
    /// body: the engine reports several samples a second per active row.
    public private(set) var state: DownloadState

    /// Builds a leaf from the queue's own row value.
    public init(item: DownloadItem) {
        id = item.id
        canonicalVideoID = item.canonicalVideoID
        title = item.displayTitle
        uploader = item.uploader
        thumbnailURL = item.thumbnailURL
        resolvedFormat = item.resolvedFormat
        state = item.state
    }

    /// The completion fraction to draw, in `0...1`, or `nil` while the phase is
    /// indeterminate (metadata prefetch, post-processing).
    ///
    /// Derived from ``state``, so reading it registers the same single dependency a
    /// caption does — both belong in the same leaf.
    public var fraction: Double? {
        state.fraction
    }

    /// Folds a queue snapshot's copy of this row in — the lazily-enriched descriptive
    /// fields ONLY.
    ///
    /// ``state`` is deliberately NOT taken from the snapshot. A snapshot published to
    /// enrich a title carries the row's PRE-enrichment state, so adopting it would
    /// rewind the live bar; the progress seam stays authoritative for as long as the
    /// row is active. Each write is equality-guarded because `@Observable` invalidates
    /// on same-value writes.
    func refresh(from item: DownloadItem) {
        let incomingTitle = item.displayTitle
        if title != incomingTitle { title = incomingTitle }
        if uploader != item.uploader { uploader = item.uploader }
        if thumbnailURL != item.thumbnailURL { thumbnailURL = item.thumbnailURL }
        if resolvedFormat != item.resolvedFormat { resolvedFormat = item.resolvedFormat }
    }

    /// Records a live progress sample, equality-guarded for the same reason.
    func apply(_ incoming: DownloadState) {
        guard state != incoming else { return }
        state = incoming
    }
}
