// DownloadsViewModel — the presentation surface over the YouTube download queue:
// display rows for the Downloads pane, the paste entry point, and the queue-editing
// intents (remove / move / pause / resume / cancel).
//
// It is injected with `any DownloadQueueing` — NEVER the concrete `DownloadQueueService`
// — so a test drives it against `FakeDownloadQueue` with no process and no network, and
// so nothing here can reach a tool manager. Membership comes from a
// ``DownloadQueueStore`` the composition root feeds from the same service's seams;
// this view model owns the projection and the intents, never the ingestion.
//
// This file imports only Foundation + Observation + Services + Persistence; it MUST
// NOT import AppKit or UIKit (PlayerCore portability invariant), nor URLSession or
// Process (the downloader boundary gate — `PlayerCore/Sources/ViewModels` is scanned
// wholesale by `scripts/check-ai-network-boundary.sh`). `Persistence` is here for the
// ADVISORY download-history lookup only — see `DownloadsViewModel+History.swift`.
import Foundation
import Observation
import Persistence
import Services

/// One PENDING display row of the download queue — a value type, because a waiting
/// row has no live state to observe.
///
/// ``state`` is the row's state as of the last QUEUE MUTATION. Active rows do not use
/// this type at all: they carry a live progress sample several times a second, so each
/// one is a per-item ``DownloadRowLeaf`` whose own properties a leaf view observes.
public struct DownloadRow: Identifiable, Sendable, Equatable, Hashable {
    /// The enqueue's identity — stable for the row's whole lifetime.
    public let id: UUID
    /// The fetched video title, falling back to the canonical id until metadata lands.
    /// Untranslatable content, so a call site renders it with `Text(verbatim:)`.
    public let title: String
    /// The channel name, `nil` until the metadata prefetch fills it.
    public let uploader: String?
    /// The poster frame's URL, `nil` until a metadata pass fills it. A URL, never
    /// bytes — the shell owns fetching and caching the image.
    public let thumbnailURL: URL?
    /// Where the row was in its lifecycle at the last queue mutation.
    public let state: DownloadState

    public init(item: DownloadItem) {
        id = item.id
        title = item.displayTitle
        uploader = item.uploader
        thumbnailURL = item.thumbnailURL
        state = item.state
    }
}

/// What one paste did, in the single shape the confirmation flow needs.
///
/// ONE struct carries the counts AND the pending playlist because a paste routinely
/// mixes single videos with a playlist URL: the person is told "N added, M skipped"
/// and asked to confirm the expansion in the same breath. Splitting them would force
/// the caller to pick one fact and lose the other.
public struct DownloadPasteReport: Sendable, Equatable, Hashable {
    /// How many rows were appended to the queue.
    public let added: Int
    /// How many URLs resolved to a canonical id already queued or downloading.
    public let duplicatesDropped: Int
    /// A playlist expansion awaiting confirmation, when the paste contained one.
    public let pendingPlaylist: EnqueueOutcome.PendingPlaylist?

    public init(added: Int, duplicatesDropped: Int, pendingPlaylist: EnqueueOutcome.PendingPlaylist? = nil) {
        self.added = added
        self.duplicatesDropped = duplicatesDropped
        self.pendingPlaylist = pendingPlaylist
    }

    public init(outcome: EnqueueOutcome) {
        self.init(
            added: outcome.added,
            duplicatesDropped: outcome.duplicatesDropped,
            pendingPlaylist: outcome.pendingPlaylist
        )
    }

    /// The report that changed nothing — a paste of junk, or a stale confirmation.
    public static let zero = DownloadPasteReport(added: 0, duplicatesDropped: 0)

    /// Whether a playlist is being held for the person to confirm.
    public var needsConfirmation: Bool {
        pendingPlaylist != nil
    }

    /// Whether the paste produced nothing worth reporting at all.
    public var isEmpty: Bool {
        added == 0 && duplicatesDropped == 0 && pendingPlaylist == nil
    }
}

/// Projects the download queue into display rows and forwards the person's intents to
/// the queue seam.
@MainActor
@Observable
public final class DownloadsViewModel {
    /// The membership projection the composition root feeds from `onQueueChanged` /
    /// `onItemProgress`. Held by reference (the reference itself never changes), so a
    /// leaf view can read its live progress fields directly.
    @ObservationIgnored public let store: DownloadQueueStore

    @ObservationIgnored private let queue: any DownloadQueueing

    /// The download log, consulted ONLY by the advisory paste hint and never by any
    /// enqueue path. `nil` — the default — disables the hint outright, which is what
    /// keeps every queue-only test and every non-macOS shell free of a database.
    @ObservationIgnored let history: (any DownloadHistoryRepositoryProviding)?

    public init(
        queue: any DownloadQueueing,
        store: DownloadQueueStore,
        history: (any DownloadHistoryRepositoryProviding)? = nil
    ) {
        self.queue = queue
        self.store = store
        self.history = history
    }

    /// The rows transferring right now, in the driver's dequeue order — one observable
    /// leaf each, so a view renders one progress bar per row and each bar re-renders
    /// only on its OWN row's samples.
    public var activeRows: [DownloadRowLeaf] {
        store.activeRows
    }

    /// The waiting rows in queue (FIFO) order, bounded by the store's display window.
    public var pendingRows: [DownloadRow] {
        store.pendingItems.map { DownloadRow(item: $0) }
    }

    /// Whether ANY transfer is running right now.
    ///
    /// Distinct from ``isWorking``, and the two are not interchangeable: pausing stops
    /// the queue picking up new work but leaves in-flight transfers running, so a
    /// paused queue reports `false` for ``isWorking`` while this still reports `true`.
    /// A caller that must not disturb a running child — replacing the engine binary,
    /// for instance — has to read THIS one.
    public var hasActiveDownloads: Bool {
        !store.activeRows.isEmpty
    }

    /// How many pending rows exist beyond the mirrored window.
    public var pendingOverflow: Int {
        store.pendingOverflow
    }

    /// Total rows the queue holds, including those past the display window.
    public var count: Int {
        store.count
    }

    public var isEmpty: Bool {
        store.isEmpty
    }

    public var isPaused: Bool {
        store.isPaused
    }

    public var isWorking: Bool {
        store.isWorking
    }

    // MARK: - Paste

    /// Accepts pasted `urls` and reports what happened.
    ///
    /// A playlist in the paste is EXPANDED BUT HELD: the report carries a
    /// ``DownloadPasteReport/pendingPlaylist`` and nothing is queued for it until
    /// ``confirmPlaylist(_:)`` is called with that token.
    public func enqueue(urls: [URL]) async -> DownloadPasteReport {
        await DownloadPasteReport(outcome: queue.enqueue(urls: urls))
    }

    /// Commits the playlist expansion held under `token`. A stale token reports
    /// ``DownloadPasteReport/zero`` — an expired confirmation is "0 added", not an error.
    public func confirmPlaylist(_ token: UUID) async -> DownloadPasteReport {
        await DownloadPasteReport(outcome: queue.confirmPlaylist(token))
    }

    // MARK: - Queue intents

    /// Removes a PENDING row. A no-op for the in-flight row.
    public func remove(_ id: UUID) {
        queue.removePending(id)
    }

    /// Moves a PENDING row to `index` (clamped by the queue).
    public func move(_ id: UUID, to index: Int) {
        queue.movePending(id, to: index)
    }

    /// Stops the queue starting anything new; transfers already running finish.
    public func pause() {
        queue.pause()
    }

    /// Resumes the driver. Idempotent.
    public func resume() {
        queue.resume()
    }

    /// Flips the driver between paused and running, for a single state-aware control.
    public func togglePaused() {
        if store.isPaused { queue.resume() } else { queue.pause() }
    }

    /// Cancels ONE in-flight transfer, leaving its siblings running.
    public func cancel(_ id: UUID) {
        queue.cancel(itemID: id)
    }

    /// Cancels every in-flight transfer and clears every pending row.
    public func cancelAll() {
        queue.cancelAll()
    }
}
