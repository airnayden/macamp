// DownloadQueueService — the in-memory FIFO behind every YouTube audio download.
//
// # Single item authority
// ``DownloadQueueService/active`` is the SOLE authoritative copy of an in-flight row.
// A driver's local `item` is an IMMUTABLE token — `id` and `canonicalVideoID` and
// nothing else — from the moment the pump appends it. Every mutable read (the enriched
// title, the stamped format, the terminal state) goes back to `active` BY ID, because a
// row enriches in place while its transfer runs and a local copy captured before that
// is stale by the time the outcome lands. This is why `onItemFinished` carries the
// enriched title rather than the bare canonical id it was queued with.
//
// # A @MainActor class, deliberately NOT an actor
// `KaraokeRenderService` precedent. Every caller is the UI (paste, confirm, pause,
// reorder) and both seams publish back to the UI, so main-actor isolation removes a hop
// in each direction AND — the load-bearing part — makes seam ordering observable:
// a snapshot is emitted AFTER the mutation that caused it, on the same actor that made
// it, so an observer can never see a snapshot that disagrees with the state that
// produced it. An actor would reintroduce exactly the interleaving this design removes.
// The blocking work (spawning and draining the engine) lives in
// `Task.detached(priority: .utility)`, so the main actor is never held during a transfer.
//
// # Nothing here is persisted
// Karaoke precedent again: the queue is in-memory only, so a relaunch starts empty by
// design. No GRDB table, no snapshot, no `UserDefaults` key — and in particular no
// download destination path is ever written anywhere by this service.
//
// # This service never touches the library
// Completion fires ``DownloadQueueService/onItemFinished`` with the engine's own
// `after_move` path and stops. The composition root is what turns that into an explicit
// import; the queue has no repository, no scanner, and no opinion about either.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// A playlist expansion held back until the person confirms it.
///
/// The entries are kept SERVICE-SIDE rather than handed to the caller: the confirmation
/// sheet only needs a count, and holding the rows here means the confirmation round-trip
/// carries nothing but an opaque token.
struct HeldPlaylist {
    let token: UUID
    let items: [DownloadItem]
}

/// Production ``DownloadQueueing``: a bounded number of downloads at a time, FIFO,
/// cancellable, with playlist expansion held behind an explicit confirmation.
@MainActor
public final class DownloadQueueService: DownloadQueueing {
    public var onQueueChanged: (@Sendable (DownloadQueueSnapshot) -> Void)?
    public var onItemProgress: (@Sendable (UUID, DownloadState) -> Void)?

    /// Fires on the main actor once a download has landed at its final `after_move`
    /// path, carrying the finished row and that path.
    ///
    /// The composition root uses this success-only callback to import the file.
    public var onItemFinished: (@Sendable (DownloadItem, URL) -> Void)?

    /// Fires on the main actor for a failed attempt that can be retried from History.
    public var onItemFailed: (@Sendable (DownloadItem, DownloadError) -> Void)?

    let toolProvider: any DownloadToolProviding
    let processRunner: any ToolProcessRunning
    let stagingDirectory: URL
    let destinationDirectory: @Sendable () -> URL
    let downloadFormat: @Sendable () -> DownloadFormat
    let isDirectoryWritable: @Sendable (URL) -> Bool
    let maxConcurrent: @Sendable () -> Int
    let oEmbedFetcher: (any OEmbedFetching)?

    /// Internal rather than private: the driver lives in a sibling file, and Swift scopes
    /// `private` to the declaring file plus its same-file extensions.
    var pending: [DownloadItem] = []

    /// The rows in flight, in the order the pump dequeued them.
    ///
    /// # This array is the single authority for an in-flight row
    /// `active` holds the ONLY copy of a row that anything may read a mutable field
    /// from. A driver's local `item` is an immutable id/videoID token: enrichment, the
    /// format stamp, ``applyOutcome(_:for:)``, ``settle(_:)`` and `onItemFinished` all
    /// look the row up here BY ID and write back here. Holding a local copy across an
    /// `await` and reading its fields afterwards is the one mistake this design exists
    /// to make impossible — the copy predates the enrichment the transfer ran alongside.
    ///
    /// Its COUNT is also the concurrency mutex. The pump increments it synchronously,
    /// before any suspension point, so a reentrant `append()` or settle that re-enters
    /// the pump sees the slot already taken and cannot overspawn.
    var active: [DownloadItem] = []
    var isPaused = false
    var heldPlaylist: HeldPlaylist?
    var drivers: [UUID: Task<Void, Never>] = [:]
    var metadataWork: [UUID: Task<YtDlpInfoPayload?, Error>] = [:]
    var transferWork: [UUID: Task<DownloadRunResult, Error>] = [:]
    var decorationWork: [UUID: Task<Void, Never>] = [:]

    /// The `-J` listing behind a playlist EXPANSION, which belongs to no row.
    ///
    /// Tracked separately from ``metadataWork`` because that map is keyed by row id and
    /// an expansion has none: it runs before the entries exist. A cancel must still
    /// reach it, or `cancelAll()` during a 500-entry listing would leave the child
    /// running.
    var playlistExpansionWork: Task<YtDlpInfoPayload?, Error>?

    /// The rows a person has asked to stop, by id.
    ///
    /// A SET rather than one latch because several transfers run at once: "was this
    /// stopped on purpose" is a question about one row, and a shared flag answers it for
    /// all of them — cancelling one row would make its siblings' own SIGTERM read as a
    /// cancellation too. An id is inserted by ``requestCancellation(of:)`` and removed by
    /// the driver's `settle`, so the set only ever holds rows that are still in flight.
    var cancellationRequested: Set<UUID> = []
    var lastPublishedState: [UUID: DownloadState] = [:]

    /// - Parameters:
    ///   - toolProvider: Resolves the engine binary and the ffmpeg directory. Only its
    ///     ``DownloadToolProviding`` surface is used; the queue never updates the tools.
    ///   - processRunner: The one way this service reaches a child process.
    ///   - stagingDirectory: yt-dlp's `-P temp:` — partial files never touch the
    ///     destination folder.
    ///   - destinationDirectory: The configured downloads folder, read at DEQUEUE time
    ///     so a settings change applies to future items without disturbing the queue.
    ///   - downloadFormat: The configured format, read at dequeue for the same reason.
    ///   - isDirectoryWritable: The destination writability probe. Injected because the
    ///     real probe is a write-then-delete the APP must perform (a CLI child cannot
    ///     raise a TCC prompt), and because it makes the failure path scriptable.
    ///   - maxConcurrent: How many transfers may run at once, read at EVERY refill and
    ///     clamped to one through ``DownloadQueueLimits/maxConcurrentDownloads``. A
    ///     closure rather than a stored number so a settings change takes effect on the
    ///     next row the pump picks up, never retroactively on one already transferring.
    ///   - oEmbedFetcher: The keyless paste-time decoration seam. `nil` — the default —
    ///     disables decoration entirely; see `DownloadQueueService+Decoration.swift`.
    public init(
        toolProvider: any DownloadToolProviding,
        processRunner: any ToolProcessRunning,
        stagingDirectory: URL,
        destinationDirectory: @escaping @Sendable () -> URL,
        downloadFormat: @escaping @Sendable () -> DownloadFormat = { .default },
        isDirectoryWritable: @escaping @Sendable (URL) -> Bool = { _ in true },
        maxConcurrent: @escaping @Sendable () -> Int = { DownloadQueueLimits.defaultConcurrentDownloads },
        oEmbedFetcher: (any OEmbedFetching)? = nil
    ) {
        self.toolProvider = toolProvider
        self.processRunner = processRunner
        self.stagingDirectory = stagingDirectory
        self.destinationDirectory = destinationDirectory
        self.downloadFormat = downloadFormat
        self.isDirectoryWritable = isDirectoryWritable
        self.maxConcurrent = maxConcurrent
        self.oEmbedFetcher = oEmbedFetcher
    }
}

// MARK: - Enqueue (DownloadQueueing)

public extension DownloadQueueService {
    /// Accepts a paste: singles are appended immediately, playlists are expanded and
    /// HELD, and all three facts ride one ``EnqueueOutcome``.
    ///
    /// The singles are appended BEFORE the expansion runs, so a mixed paste starts
    /// downloading while the (network-bound) playlist listing is still resolving.
    /// Any previously held-but-unconfirmed expansion is discarded first — a new paste
    /// supersedes a confirmation the person walked away from.
    func enqueue(urls: [URL]) async -> EnqueueOutcome {
        heldPlaylist = nil
        var singles: [DownloadItem] = []
        var playlistURLs: [URL] = []
        for url in urls {
            if YouTubeURLNormalizer.isPlaylistURL(url) {
                playlistURLs.append(url)
            } else if let videoID = YouTubeURLNormalizer.canonicalVideoID(from: url) {
                singles.append(DownloadItem(canonicalVideoID: videoID, sourceURL: url))
            }
        }
        let appended = append(singles)
        let pendingPlaylist = await expandPlaylists(playlistURLs)
        return EnqueueOutcome(
            added: appended.added,
            duplicatesDropped: appended.duplicatesDropped,
            pendingPlaylist: pendingPlaylist
        )
    }

    /// Appends the entries held under `pendingToken`.
    ///
    /// Dedup runs HERE rather than at expansion time: the queue may have changed while
    /// the confirmation sheet was open, so the entries are checked against the queue as
    /// it is now, and the drop count reported is the one the person actually incurred.
    func confirmPlaylist(_ pendingToken: UUID) async -> EnqueueOutcome {
        guard let held = heldPlaylist, held.token == pendingToken else { return .zero }
        heldPlaylist = nil
        let appended = append(held.items)
        return EnqueueOutcome(added: appended.added, duplicatesDropped: appended.duplicatesDropped)
    }
}

// MARK: - Transport (DownloadQueueing)

public extension DownloadQueueService {
    /// Cancels every row currently in flight and lets the pump refill behind them. Rows
    /// are DROPPED, not requeued — that is what separates this from ``pause()``.
    func cancelCurrent() {
        for item in active {
            requestCancellation(of: item.id)
        }
    }

    /// Cancels ONE in-flight row by id, leaving its siblings running. A no-op for a row
    /// that is not in flight.
    func cancel(itemID: UUID) {
        requestCancellation(of: itemID)
    }

    /// Stops the pump from picking up anything NEW. Rows already in flight run to
    /// completion; nothing is cancelled, nothing is requeued.
    ///
    /// # Why refill-stop rather than stop-and-requeue
    /// A restarted download restarts from zero — the engine owns its partial file and
    /// this service makes no claim about resuming it. Interrupting three transfers that
    /// are 90% done to honour "pause" therefore throws away far more than it saves, and
    /// the person who paused almost always meant "stop taking on more", not "discard
    /// what is nearly finished". Dropping a specific row is what ``cancel(itemID:)`` is
    /// for, and it stays available while paused.
    func pause() {
        isPaused = true
        emitQueueChanged()
    }

    /// Idempotently clears the paused latch and starts pending work.
    func resume() {
        isPaused = false
        emitQueueChanged()
        pump()
    }

    /// Removes a PENDING row. A no-op for an in-flight row (use ``cancel(itemID:)``)
    /// or an unknown id.
    func removePending(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index)
        emitItemState(.cancelled, for: id)
        emitQueueChanged()
    }

    /// Moves a PENDING row to `index`, clamped to the pending range.
    func movePending(_ id: UUID, to index: Int) {
        guard let from = pending.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index, 0), pending.count - 1)
        guard target != from else { return }
        let item = pending.remove(at: from)
        pending.insert(item, at: target)
        emitQueueChanged()
    }

    /// Cancels every in-flight row, drops every pending row, and discards any held
    /// playlist confirmation.
    ///
    /// The playlist EXPANSION is cancelled here and nowhere else: it belongs to no row,
    /// so no per-item cancel can reach it, and a `cancelAll()` raised during a 500-entry
    /// listing would otherwise leave that child running.
    func cancelAll() {
        let cleared = pending
        pending.removeAll()
        heldPlaylist = nil
        playlistExpansionWork?.cancel()
        cancelDecorations()
        for item in active {
            requestCancellation(of: item.id)
        }
        for item in cleared {
            emitItemState(.cancelled, for: item.id)
        }
        emitQueueChanged()
    }
}

// MARK: - Membership

extension DownloadQueueService {
    /// What one append actually did. A named type rather than a tuple because SwiftLint's
    /// `large_tuple` ceiling is two members and this is already at it.
    struct AppendResult {
        let added: Int
        let duplicatesDropped: Int
    }

    /// Appends `items`, dropping any whose canonical id is already in flight or pending,
    /// and stopping at ``DownloadQueueLimits/maxQueueDepth``.
    ///
    /// A row refused by the depth cap is NOT a duplicate and is not reported as one — it
    /// simply never lands, which is the whole point of the cap: a queue that accepted it
    /// would starve it instead.
    @discardableResult
    func append(_ items: [DownloadItem]) -> AppendResult {
        var known = queuedVideoIDs()
        var depth = pending.count + active.count
        var accepted: [DownloadItem] = []
        var duplicatesDropped = 0
        for item in items {
            guard known.insert(item.canonicalVideoID).inserted else {
                duplicatesDropped += 1
                continue
            }
            guard depth < DownloadQueueLimits.maxQueueDepth else { break }
            depth += 1
            accepted.append(item)
        }
        guard !accepted.isEmpty else {
            return AppendResult(added: 0, duplicatesDropped: duplicatesDropped)
        }
        pending.append(contentsOf: accepted)
        for item in accepted {
            emitItemState(.queued, for: item.id)
        }
        emitQueueChanged()
        pump()
        decoratePendingRows(accepted)
        return AppendResult(added: accepted.count, duplicatesDropped: duplicatesDropped)
    }

    /// The canonical ids the queue is already committed to: every in-flight row plus
    /// every pending row. Deliberately NOT the history — a video whose first attempt was
    /// cancelled must be re-queueable.
    func queuedVideoIDs() -> Set<String> {
        Set(pending.map(\.canonicalVideoID)).union(active.map(\.canonicalVideoID))
    }
}

// MARK: - Seam publication

extension DownloadQueueService {
    /// Publishes a progress sample for `id`, DROPPING it when `id` is no longer in
    /// flight.
    ///
    /// This is the anti-resurrection guard: a sample produced before a cancel and
    /// delivered after it must not put a removed row back on screen. Membership in
    /// ``active`` is the whole test, so a sample for one row is never judged against
    /// another row's identity — with several transfers running, "is this the current
    /// row" is not a question that has an answer. The terminal transition goes through
    /// ``emitItemState(_:for:)`` directly, because by then the row has deliberately left
    /// the queue.
    func publishProgress(_ state: DownloadState, for id: UUID) {
        guard active.contains(where: { $0.id == id }) else { return }
        emitItemState(state, for: id)
    }

    /// Publishes `state` for `id`, skipping a sample identical to the previous one.
    ///
    /// The equality guard lives here rather than in every observer because
    /// `@Observable` invalidates on same-value writes (macOS UI-perf rule), and the
    /// engine happily reports the same fraction twice while a transfer stalls.
    func emitItemState(_ state: DownloadState, for id: UUID) {
        guard lastPublishedState[id] != state else { return }
        lastPublishedState[id] = state.isTerminal ? nil : state
        onItemProgress?(id, state)
    }

    /// Publishes the post-mutation snapshot. Every membership or paused-state change
    /// ends with exactly one of these.
    func emitQueueChanged() {
        onQueueChanged?(DownloadQueueSnapshot(
            activeItems: active,
            pendingItems: pending,
            isPaused: isPaused
        ))
    }

    /// Marks ONE in-flight download as person-requested-stopped, kills its children, and
    /// reclaims that row's staging files. A no-op for a row that is not in flight.
    ///
    /// Membership in ``cancellationRequested`` is what makes the SIGNAL termination that
    /// follows read as ``DownloadError/cancelled`` rather than a fault —
    /// `YtDlpProgressParser` owns the mapping, this service owns the intent. Keyed by id
    /// so a sibling that is killed for a real reason at the same moment still reports its
    /// own fault.
    ///
    /// The row's DRIVER task is deliberately NOT cancelled. Everything the driver is
    /// waiting on lives in ``metadataWork``/``transferWork``, so cancelling those already
    /// unblocks it immediately — while cancelling the driver itself would make an
    /// `await` it has not reached yet throw first, and the row would settle as
    /// `.toolMissing` instead of `.cancelled`. The driver is also the only thing that
    /// retires the row at all.
    ///
    /// The purge happens HERE, synchronously, rather than only once the driver settles
    /// the row, because the quit teardown calls `cancelAll()` and the process may be
    /// gone before the driver ever runs again. Unlinking a file the signalled child is
    /// still writing is safe — the bytes go to an inode with no directory entry, which
    /// the kernel reclaims when the child exits.
    ///
    /// Scope is ``DownloadStagingPurgeScope/allArtifacts`` unconditionally: a cancelled
    /// row is dropped, never requeued, so nothing downstream can resume from the `.part`
    /// it leaves behind and keeping it would only strand the bytes.
    func requestCancellation(of itemID: UUID) {
        guard let item = active.first(where: { $0.id == itemID }) else { return }
        cancellationRequested.insert(itemID)
        metadataWork[itemID]?.cancel()
        transferWork[itemID]?.cancel()
        purgeStagingArtifacts(of: item, scope: .allArtifacts)
    }
}
