// Download queue value types — the snapshot, the caps, and the two outcome vocabularies.
//
// `DownloadQueueSnapshot` deliberately mirrors `KaraokeQueueSnapshot` (active items +
// pending items in the driver's exact pick order + paused flag), so the downloads
// sidebar can be built the same way the karaoke queue pane was, and so both seams
// publish a post-mutation snapshot rather than a mutation description. The active side
// is a LIST rather than one optional item because the driver runs several transfers at
// once; a single-transfer queue is simply the case where that list holds one item.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit or Process
// (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// A snapshot of the download queue's membership and paused state, published after
/// every mutation so an observer can mirror the active items, the pending items, and
/// whether the driver is paused.
///
/// Mirrors `KaraokeQueueSnapshot`; carries whole ``DownloadItem`` values rather than
/// identifiers because a download row's descriptive fields enrich in place and the
/// observer must see them without a second lookup.
public struct DownloadQueueSnapshot: Sendable, Equatable {
    /// The items downloading right now, in the order the driver dequeued them. Empty
    /// when nothing is in flight.
    public let activeItems: [DownloadItem]
    /// The pending items in the driver's exact FIFO pick order.
    public let pendingItems: [DownloadItem]
    /// Whether the driver is paused — in-flight work is cancelled and requeued.
    public let isPaused: Bool

    public init(activeItems: [DownloadItem], pendingItems: [DownloadItem], isPaused: Bool) {
        self.activeItems = activeItems
        self.pendingItems = pendingItems
        self.isPaused = isPaused
    }

    /// An empty, running queue — the state before anything is enqueued.
    public static let empty = DownloadQueueSnapshot(activeItems: [], pendingItems: [], isPaused: false)

    /// Total rows the queue is tracking (in flight plus pending).
    public var count: Int {
        pendingItems.count + activeItems.count
    }

    /// Whether the queue holds no work at all.
    public var isEmpty: Bool {
        count == 0
    }
}

/// The caps and defaults the download queue enforces.
///
/// OWNER-TUNABLE CONSTANTS: these are product decisions, not physics. They exist so a
/// pasted mega-playlist cannot balloon the in-memory queue or the confirmation sheet
/// into something unusable, and so parallel transfers stay inside what one network
/// link and one listener's attention can actually absorb. Change them here — they are
/// the single source of truth and nothing may hardcode a competing literal.
public enum DownloadQueueLimits {
    /// The most entries a single playlist expansion may contribute. Expansion beyond
    /// this is truncated and reported through `EnqueueOutcome.PendingPlaylist.capped`.
    public static let maxPlaylistExpansion = 500
    /// The most rows the queue may hold at once (in flight plus pending). Enqueues
    /// that would exceed it are dropped rather than accepted and starved.
    public static let maxQueueDepth = 1000
    /// The most transfers that may run at once — the ceiling a listener's own setting
    /// is clamped to. OWNER-TUNABLE: four is a judgement about bandwidth sharing and
    /// per-child memory, not a measured limit of the engine.
    public static let maxConcurrentDownloads = 4
    /// How many transfers run at once before a listener changes it. OWNER-TUNABLE: it
    /// sits one below ``maxConcurrentDownloads`` so the shipped default leaves room to
    /// go faster rather than starting at the ceiling.
    public static let defaultConcurrentDownloads = 3
}

/// What an enqueue attempt actually did.
///
/// A STRUCT, not an enum, on purpose: one paste routinely mixes single videos with a
/// playlist URL, so the caller needs the accepted count, the dedup count, AND any
/// pending playlist confirmation *at the same time*. An enum would force the caller
/// to pick one fact and lose the others.
public struct EnqueueOutcome: Sendable, Equatable, Hashable {
    /// A playlist expansion held back awaiting the person's confirmation.
    ///
    /// The service has already expanded the playlist and is holding the entries under
    /// ``token``; nothing is queued until `confirmPlaylist(_:)` is called with it.
    public struct PendingPlaylist: Sendable, Equatable, Hashable {
        /// The service-side handle for the held entries. Opaque to the caller.
        public let token: UUID
        /// How many entries are being held (already truncated when ``capped``).
        public let count: Int
        /// Whether the playlist was longer than ``DownloadQueueLimits/maxPlaylistExpansion``
        /// and was truncated to it.
        public let capped: Bool

        public init(token: UUID, count: Int, capped: Bool) {
            self.token = token
            self.count = count
            self.capped = capped
        }
    }

    /// How many rows were actually appended to the queue.
    public let added: Int
    /// How many URLs resolved to a canonical id already queued or downloading.
    public let duplicatesDropped: Int
    /// A playlist expansion awaiting confirmation, when the paste contained one.
    public let pendingPlaylist: PendingPlaylist?

    public init(added: Int, duplicatesDropped: Int, pendingPlaylist: PendingPlaylist? = nil) {
        self.added = added
        self.duplicatesDropped = duplicatesDropped
        self.pendingPlaylist = pendingPlaylist
    }

    /// The outcome that changed nothing.
    ///
    /// Returned by `confirmPlaylist(_:)` for a stale or already-discarded token — the
    /// UI reports "0 added" rather than treating an expired confirmation as an error.
    public static let zero = EnqueueOutcome(added: 0, duplicatesDropped: 0, pendingPlaylist: nil)
}

/// How a single download ended.
///
/// The return vocabulary of the engine-termination map: a process exit (status plus
/// `normalExit`/`uncaughtSignal` reason) collapses onto exactly one of these.
public enum DownloadOutcome: Sendable, Equatable, Hashable {
    /// The download finished and the file is at `filePath`.
    ///
    /// A path `String`, not a `URL`: it is the engine's own reported destination,
    /// carried verbatim from the tool's machine-readable output before the queue
    /// interprets it.
    case completed(filePath: String)
    /// The download stopped with a typed failure.
    case failed(DownloadError)
}
