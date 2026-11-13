// FakeDownloadQueue — an in-memory ``DownloadQueueing`` double.
//
// A deterministic stand-in for the production download queue: it normalizes URLs
// through the real `YouTubeURLNormalizer` (so dedup and the playlist precedence rule
// behave exactly as they will in production), models a live queue (`activeItems` +
// `pendingItems` + `isPaused`) that mirrors the real snapshot behavior, and lets a
// test advance the driver through ``startNext()`` and push row updates through
// ``emitProgress(id:state:)`` / ``finish(id:state:)`` as if a background transfer
// reported them. It spawns no process and touches no network. `@MainActor`, mirroring
// the protocol's isolation and the `FakeKaraokeRenderer` style.
//
// ``startNext()`` starts exactly ONE row per call, up to ``maxConcurrent``, so a test
// that wants three rows in flight says so three times and one that wants a serial queue
// needs no configuration at all.
import Foundation
import Services

/// An in-memory ``DownloadQueueing`` for hermetic tests and previews.
@MainActor
public final class FakeDownloadQueue: DownloadQueueing {
    public private(set) var activeItems: [DownloadItem] = []
    public private(set) var pendingItems: [DownloadItem] = []
    public private(set) var isPaused = false
    public private(set) var enqueuedURLs: [URL] = []
    public private(set) var confirmedTokens: [UUID] = []
    public private(set) var cancelCurrentCallCount = 0
    public private(set) var cancelledItemIDs: [UUID] = []
    public private(set) var pauseCallCount = 0
    public private(set) var resumeCallCount = 0
    public private(set) var cancelAllCallCount = 0

    /// How many rows ``startNext()`` will let run at once.
    public var maxConcurrent: Int

    /// Canonical video ids a playlist URL expands to. A playlist URL absent from this
    /// map expands to nothing, so a test opts in to expansion explicitly.
    public var playlistExpansion: [URL: [String]] = [:]

    public var onQueueChanged: (@Sendable (DownloadQueueSnapshot) -> Void)?
    public var onItemProgress: (@Sendable (UUID, DownloadState) -> Void)?

    private var heldPlaylists: [UUID: [DownloadItem]] = [:]

    public init(maxConcurrent: Int = DownloadQueueLimits.defaultConcurrentDownloads) {
        self.maxConcurrent = maxConcurrent
    }

    // MARK: - DownloadQueueing

    /// Appends one row per newly-seen canonical id and holds every playlist expansion
    /// in the paste under a SINGLE token (the real service may split them; the double
    /// unions them so a test has exactly one token to confirm).
    public func enqueue(urls: [URL]) async -> EnqueueOutcome {
        enqueuedURLs.append(contentsOf: urls)
        var singles: [DownloadItem] = []
        var playlistEntries: [DownloadItem] = []
        for url in urls {
            if YouTubeURLNormalizer.isPlaylistURL(url) {
                playlistEntries.append(contentsOf: expand(url))
            } else if let videoID = YouTubeURLNormalizer.canonicalVideoID(from: url) {
                singles.append(DownloadItem(canonicalVideoID: videoID, sourceURL: url))
            }
        }
        let appended = append(singles)
        let pendingPlaylist = hold(playlistEntries)
        if appended.added > 0 { emitQueueChanged() }
        return EnqueueOutcome(
            added: appended.added,
            duplicatesDropped: appended.duplicatesDropped,
            pendingPlaylist: pendingPlaylist
        )
    }

    public func confirmPlaylist(_ pendingToken: UUID) async -> EnqueueOutcome {
        confirmedTokens.append(pendingToken)
        guard let entries = heldPlaylists.removeValue(forKey: pendingToken) else {
            return .zero
        }
        let appended = append(entries)
        if appended.added > 0 { emitQueueChanged() }
        return EnqueueOutcome(added: appended.added, duplicatesDropped: appended.duplicatesDropped)
    }

    public func cancelCurrent() {
        cancelCurrentCallCount += 1
        let cancelled = activeItems
        guard !cancelled.isEmpty else { return }
        activeItems.removeAll()
        emitQueueChanged()
        for item in cancelled {
            onItemProgress?(item.id, .cancelled)
        }
    }

    /// Drops exactly ONE in-flight row and leaves its siblings running.
    public func cancel(itemID: UUID) {
        cancelledItemIDs.append(itemID)
        guard let index = activeItems.firstIndex(where: { $0.id == itemID }) else { return }
        activeItems.remove(at: index)
        emitQueueChanged()
        onItemProgress?(itemID, .cancelled)
    }

    public func removePending(_ id: UUID) {
        guard let index = pendingItems.firstIndex(where: { $0.id == id }) else { return }
        pendingItems.remove(at: index)
        emitQueueChanged()
    }

    public func movePending(_ id: UUID, to index: Int) {
        guard let from = pendingItems.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index, 0), pendingItems.count - 1)
        guard target != from else { return }
        let item = pendingItems.remove(at: from)
        pendingItems.insert(item, at: target)
        emitQueueChanged()
    }

    /// Refill-stop, mirroring the production contract: ``startNext()`` stops handing out
    /// slots, and whatever is already in `activeItems` stays there until a test finishes
    /// or cancels it.
    public func pause() {
        pauseCallCount += 1
        isPaused = true
        emitQueueChanged()
    }

    public func resume() {
        resumeCallCount += 1
        isPaused = false
        emitQueueChanged()
    }

    public func cancelAll() {
        cancelAllCallCount += 1
        activeItems.removeAll()
        pendingItems.removeAll()
        heldPlaylists.removeAll()
        emitQueueChanged()
    }

    // MARK: - Test helpers

    /// Simulates the driver picking up ONE pending row into a free slot.
    public func startNext() {
        guard !isPaused, activeItems.count < maxConcurrent, !pendingItems.isEmpty else { return }
        var item = pendingItems.removeFirst()
        item.state = .fetchingMetadata
        activeItems.append(item)
        emitQueueChanged()
        onItemProgress?(item.id, item.state)
    }

    /// Fires ``onItemProgress`` for `id` and updates the row in place, as a background
    /// transfer would.
    public func emitProgress(id: UUID, state: DownloadState) {
        if let index = activeItems.firstIndex(where: { $0.id == id }) {
            activeItems[index].state = state
        } else if let index = pendingItems.firstIndex(where: { $0.id == id }) {
            pendingItems[index].state = state
        }
        onItemProgress?(id, state)
    }

    /// Completes one in-flight row with a terminal `state`: the row leaves the queue,
    /// the row update is published, and only then the snapshot.
    ///
    /// That order is the production driver's, not a convenience: `settle(_:)`
    /// (`DownloadQueueService+Driver.swift`) does `active.removeAll` → `emitItemState` →
    /// `emitQueueChanged`, so a drain's last terminal state is always published while
    /// the queue still reads non-empty, and the empty snapshot arrives after it. An
    /// observer that counts terminal states and assesses the drain on the empty snapshot
    /// — which is exactly what `DownloadToastPolicy` does — reports one fewer row per
    /// drain if a double inverts the two, and carries the missing one into the next
    /// drain. This double previously emitted them the other way round, so any test
    /// driven through it saw the off-by-one `440a59b` had already fixed in production.
    public func finish(id: UUID, state: DownloadState) {
        let wasInFlight = activeItems.contains { $0.id == id }
        activeItems.removeAll { $0.id == id }
        onItemProgress?(id, state)
        if wasInFlight {
            emitQueueChanged()
        }
    }

    /// The token of the single playlist expansion currently held, when any.
    public var heldPlaylistToken: UUID? {
        heldPlaylists.keys.first
    }

    // MARK: - Internals

    private func expand(_ url: URL) -> [DownloadItem] {
        (playlistExpansion[url] ?? []).map { DownloadItem(canonicalVideoID: $0, sourceURL: url) }
    }

    /// Appends `items`, dropping ids already queued and refusing to exceed
    /// ``DownloadQueueLimits/maxQueueDepth``.
    private func append(_ items: [DownloadItem]) -> (added: Int, duplicatesDropped: Int) {
        var added = 0
        var duplicatesDropped = 0
        for item in items {
            guard !knownVideoIDs.contains(item.canonicalVideoID) else {
                duplicatesDropped += 1
                continue
            }
            guard pendingItems.count + activeItems.count < DownloadQueueLimits.maxQueueDepth else {
                continue
            }
            pendingItems.append(item)
            added += 1
        }
        return (added, duplicatesDropped)
    }

    private func hold(_ entries: [DownloadItem]) -> EnqueueOutcome.PendingPlaylist? {
        guard !entries.isEmpty else { return nil }
        let capped = entries.count > DownloadQueueLimits.maxPlaylistExpansion
        let held = capped ? Array(entries.prefix(DownloadQueueLimits.maxPlaylistExpansion)) : entries
        let token = UUID()
        heldPlaylists[token] = held
        return EnqueueOutcome.PendingPlaylist(token: token, count: held.count, capped: capped)
    }

    private var knownVideoIDs: Set<String> {
        Set(pendingItems.map(\.canonicalVideoID)).union(activeItems.map(\.canonicalVideoID))
    }

    private func emitQueueChanged() {
        onQueueChanged?(DownloadQueueSnapshot(
            activeItems: activeItems,
            pendingItems: pendingItems,
            isPaused: isPaused
        ))
    }
}
