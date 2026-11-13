// DownloadItemVideoIDMap — the correlation table that turns an `onItemProgress` callback
// back into the video a chat-initiated download was for.
//
// ── WHY THIS TYPE HAS TO EXIST ───────────────────────────────────────────────
//
// ``DownloadQueueing/onItemProgress`` delivers `(UUID, DownloadState)` and NOTHING else.
// The UUID is minted inside the queue at enqueue time, so a caller holding a canonical
// video id cannot recognise its own download from that pair alone. ``DownloadQueueSnapshot``
// does carry both — every ``DownloadItem`` has its `id` and its `canonicalVideoID` — so
// the correlation is learned from the snapshot seam and consulted from the progress seam,
// the same pairing the downloads sidebar already uses.
//
// ── INGEST ACCUMULATES; IT DOES NOT MIRROR ───────────────────────────────────
//
// This is the load-bearing decision, and the naive implementation gets it wrong in a way
// that passes every ordinary test. A map rebuilt from each snapshot works today only
// because `settle(_:)` publishes the terminal `onItemProgress` BEFORE the post-removal
// snapshot — invert that internal ordering and the row is already absent from the
// snapshot when its terminal state arrives, the lookup answers `nil`, and the registration
// waiting on that download is never released: no append, no eviction, no notice. So
// ``ingest(_:)`` only ever INSERTS, and the single removal path is ``prune(_:)``, called
// by the terminal-state handler after it has resolved the id.
//
// First write wins, per item id. A snapshot cannot legitimately carry one id twice
// (`DownloadItem.id` is minted per enqueue and `canonicalVideoID` is a `let`), but this
// type does not validate what the `@Sendable` seam hands it, and "a later row silently
// rewrites an in-flight correlation" is the wrong failure to inherit from a malformed
// payload. Re-ingesting the same row is therefore free, which is what makes accumulation
// safe against the snapshot-per-progress-sample rate.
//
// ── LIFETIME ─────────────────────────────────────────────────────────────────
//
// Entries live until pruned. A row that leaves the queue WITHOUT a terminal
// `onItemProgress` — `removePending(_:)` publishes only a snapshot — leaves its entry
// behind for the life of the process. That is bounded by how many rows a session
// enqueues, at a `UUID` plus an 11-character id each, and is deliberately preferred to
// the alternative: a map that dropped entries on snapshot absence is exactly the
// mirroring behaviour described above. NEVER PERSISTED — a correlation only means
// anything while the queue that minted the id is alive, and that queue is itself never
// persisted.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Correlates a download row's `UUID` with the canonical video id it was queued for.
///
/// `@MainActor` because both seams that drive it — ``DownloadQueueing/onQueueChanged`` and
/// ``DownloadQueueing/onItemProgress`` — are documented to fire on the main actor, and an
/// actor would add hops to a lookup whose whole workload is one dictionary access.
@MainActor
public final class DownloadItemVideoIDMap {
    private var videoIDs: [UUID: String] = [:]

    /// Creates an empty map. The composition root owns the single instance.
    public init() {}

    /// How many correlations are currently held. A test and diagnostics hook — the
    /// pruning contract is only checkable through it.
    public var count: Int {
        videoIDs.count
    }

    /// Records every correlation in `snapshot` that is not already known.
    ///
    /// Additive: ids absent from `snapshot` are left alone. See the file header for why
    /// that is the contract rather than an optimisation.
    public func ingest(_ snapshot: DownloadQueueSnapshot) {
        for item in snapshot.activeItems {
            insert(item)
        }
        for item in snapshot.pendingItems {
            insert(item)
        }
    }

    /// The canonical video id `itemID` was queued for, or `nil` when this map never saw
    /// a snapshot containing it (or has already pruned it).
    public func videoID(for itemID: UUID) -> String? {
        videoIDs[itemID]
    }

    /// Releases `itemID`'s correlation.
    ///
    /// The ONLY removal path, and the terminal-state handler calls it after it has
    /// finished resolving that id. Pruning an id the map never held — or the same id
    /// twice, which a repeated terminal emission would produce — is a no-op.
    public func prune(_ itemID: UUID) {
        videoIDs[itemID] = nil
    }

    private func insert(_ item: DownloadItem) {
        guard videoIDs[item.id] == nil else { return }
        videoIDs[item.id] = item.canonicalVideoID
    }
}
