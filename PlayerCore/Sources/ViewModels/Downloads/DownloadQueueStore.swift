// DownloadQueueStore — the in-memory projection of the YouTube download queue that
// drives the Downloads sidebar section: which videos are transferring right now, which
// are waiting (FIFO), whether the driver is paused, and how far each active transfer
// has progressed.
//
// This is presentation state ONLY. Like ``KaraokeQueueStore``, it is NEVER persisted
// (GRDB / snapshot / UserDefaults): the download queue is a runtime concept owned by
// `DownloadQueueService`, and this store is a transient projection of that service's
// `onQueueChanged` / `onItemProgress` seams, rebuilt from scratch every launch. It is
// wire-agnostic — the composition root connects the service's seams into it (nothing
// here reaches back), so it can be unit-tested in complete isolation.
//
// ── THE ACTIVE SIDE IS A LIST OF LEAVES, NOT A MAP OF STATES ─────────────────
//
// Several transfers run at once, so the live state is per row. It is held in one
// ``DownloadRowLeaf`` object per active row rather than in a `[UUID: DownloadState]`
// property here, because `@Observable` tracks at property granularity: a map is ONE
// property, so every bar that read it would be invalidated by every other row's tick.
// See ``DownloadRowLeaf`` for the full argument. Leaves are REUSED by id for as long as
// the row stays active — that reuse is what lets a snapshot enrich a title without
// rewinding the live bar, and what keeps the anti-resurrection guard a lookup.
//
// This file imports only Foundation + Observation + Services; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant), nor URLSession or Process (the
// downloader boundary gate — `PlayerCore/Sources/ViewModels` is scanned wholesale by
// `scripts/check-ai-network-boundary.sh`).
import Foundation
import Observation
import Services

/// Tracks the live download queue — the active rows, the pending rows in queue order,
/// and the paused flag — for the Downloads UI.
///
/// All state is in-memory and rebuilt from the queue/progress seams; nothing here is
/// persisted. The pending rows are held in a BOUNDED display window: a paste can fill
/// the queue to `DownloadQueueLimits.maxQueueDepth`, and mirroring a thousand rows
/// into observable state to render a list would cost more than the list is worth. The
/// active side needs no such window — it is capped by
/// `DownloadQueueLimits.maxConcurrentDownloads`.
@MainActor
@Observable
public final class DownloadQueueStore {
    /// The most pending rows ``pendingItems`` retains. Rows past it are counted by
    /// ``pendingOverflow`` rather than mirrored, so the store's footprint is capped
    /// regardless of how deep the queue runs.
    public static let displayWindowLimit = 100

    /// The rows transferring right now, in the driver's dequeue order — one
    /// ``DownloadRowLeaf`` each. Empty when nothing is in flight.
    ///
    /// This array changes on MEMBERSHIP only; a progress sample writes a property of
    /// one leaf and leaves the array alone, so a list body that reads it is not
    /// re-evaluated by a tick.
    public private(set) var activeRows: [DownloadRowLeaf] = []

    /// The rows waiting to transfer, in queue (FIFO) order, capped at
    /// ``displayWindowLimit``.
    public private(set) var pendingItems: [DownloadItem] = []

    /// How many pending rows exist beyond ``pendingItems`` — the part of the queue the
    /// display window does not mirror.
    public private(set) var pendingOverflow = 0

    /// Whether the driver is paused — no pending row starts until resumed. Rows already
    /// in flight are untouched, so their leaves keep reporting their real phase.
    public private(set) var isPaused = false

    /// A generation counter bumped ONLY on a membership change (which rows, in which
    /// order, and the paused flag) — never on a progress tick, and never on the
    /// in-place metadata enrichment that fills a row's title. Same design as
    /// ``KaraokeQueueStore/version``.
    public private(set) var version = 0

    /// The highest seam `sequence` applied so far; an application whose sequence is not
    /// strictly newer is dropped (the reorder guard). Starts at `-1`, not `0`, so the
    /// FIRST application is not dropped by `0 > 0` — the exact bug that once left
    /// ``KaraokeReadyStore`` empty until the next mutation.
    @ObservationIgnored private var lastAppliedSequence = -1

    /// Every live leaf by row id — the reuse table AND the progress seam's membership
    /// test. Kept in step with ``activeRows`` and deliberately NOT observable: it is
    /// addressing machinery, not rendered state.
    @ObservationIgnored private var leavesByID: [UUID: DownloadRowLeaf] = [:]

    /// Creates an empty store. The composition root connects it to the download
    /// service's queue/progress seams.
    public init() {}

    /// Total rows the queue holds — every active row plus every pending row, including
    /// those past the display window. This is the figure a sidebar badge shows.
    public var count: Int {
        pendingItems.count + pendingOverflow + activeRows.count
    }

    /// Whether the queue holds no work at all.
    public var isEmpty: Bool {
        count == 0
    }

    /// Whether the driver is actively working — at least one row is in flight and the
    /// driver is not paused. A paused or idle queue is not working, so a state-aware
    /// control shows "resume"; a working one shows "pause".
    public var isWorking: Bool {
        !activeRows.isEmpty && !isPaused
    }

    /// Applies a queue snapshot, replacing the active / pending / paused state.
    ///
    /// `sequence` must be stamped by the seam adapter at CAPTURE time — synchronously
    /// inside the `@Sendable` closure, before any hop to the main actor — because the
    /// hop is exactly what lets two snapshots arrive out of order.
    ///
    /// - Reorder guard: an application whose `sequence` is not strictly newer than the
    ///   last applied one is dropped in full.
    /// - Equality guard: each observable field is reassigned only when it actually
    ///   changes, because `@Observable` invalidates on same-value writes.
    /// - Membership: ``version`` is bumped only when the row identities, their order,
    ///   the overflow count, or the paused flag changed. A snapshot that merely
    ///   enriches a row's title refreshes that row's leaf without bumping it.
    /// - Live state: a surviving row's leaf keeps the state the progress seam gave it,
    ///   so a snapshot cannot rewind a bar with the stale sample it carries.
    public func ingest(sequence: Int, snapshot: DownloadQueueSnapshot) {
        guard sequence > lastAppliedSequence else { return }
        lastAppliedSequence = sequence

        let newPending = Array(snapshot.pendingItems.prefix(Self.displayWindowLimit))
        let newOverflow = snapshot.pendingItems.count - newPending.count
        let activeChanged = snapshot.activeItems.map(\.id) != activeRows.map(\.id)
        let membershipChanged = activeChanged
            || newPending.map(\.id) != pendingItems.map(\.id)
            || newOverflow != pendingOverflow
            || snapshot.isPaused != isPaused

        applyActiveItems(snapshot.activeItems, identitiesChanged: activeChanged)
        if pendingItems != newPending { pendingItems = newPending }
        if pendingOverflow != newOverflow { pendingOverflow = newOverflow }
        if isPaused != snapshot.isPaused { isPaused = snapshot.isPaused }

        guard membershipChanged else { return }
        version += 1
    }

    /// Records a progress sample for `id`, but only while it names an ACTIVE row.
    ///
    /// This is the anti-resurrection guard: a sample produced before a cancel and
    /// delivered after the snapshot that retired the row finds no leaf and is dropped,
    /// so a retired row can never reappear. Does NOT bump ``version`` — a consumer
    /// observes the leaf's own ``DownloadRowLeaf/state`` /
    /// ``DownloadRowLeaf/fraction`` directly.
    public func ingestProgress(id: UUID, state: DownloadState) {
        leavesByID[id]?.apply(state)
    }

    /// Reuses a leaf per surviving row id, mints one per new row, and retires the rest.
    ///
    /// Reuse is what preserves a surviving row's live state across an enrichment
    /// snapshot; the array is rewritten only when the identities actually changed,
    /// because assigning an array of the same references still invalidates every
    /// reader of ``activeRows``.
    private func applyActiveItems(_ items: [DownloadItem], identitiesChanged: Bool) {
        for item in items {
            if let leaf = leavesByID[item.id] {
                leaf.refresh(from: item)
            } else {
                leavesByID[item.id] = DownloadRowLeaf(item: item)
            }
        }
        guard identitiesChanged else { return }
        activeRows = items.compactMap { leavesByID[$0.id] }
        let live = Set(items.map(\.id))
        leavesByID = leavesByID.filter { live.contains($0.key) }
    }
}
