// ChatDownloadStatusStore — what one row of the chat suggestion table currently says
// about its own download, projected from four independent feeds.
//
// ── WHY A PROJECTION AND NOT A READ OF THE QUEUE ─────────────────────────────
//
// A suggestion row asks one question — "where is MY song?" — and the four sources that
// can answer it speak different languages and arrive out of order: the queue publishes
// whole `DownloadQueueSnapshot`s, the progress seam publishes `(UUID, DownloadState)`,
// the playlist pipeline publishes `ChatDownloadAppendEvent`s, and download history
// answers "you already have this" before any of them. None is addressed by the row's
// own key, and none carries the others' vocabulary. This type is the single place those
// four are folded into ONE value per row, so the table reads a status rather than
// re-deriving one from three seams in `body`.
//
// It is a projection in the strict sense: it NEVER reads the queue, the registry, or
// the database. Todo 9 feeds it; it only ever answers.
//
// ── TWO KEYS FOR ONE ROW ─────────────────────────────────────────────────────
//
// A suggestion the model returned with a verified video is addressed by its canonical
// video id from the start. One that carries only "title + artist" has no video id until
// the resolver finds one AT DOWNLOAD TIME, so it is addressed by a candidate key
// (`"q:" + folded(title|artist)`) instead. Both are `String`, and the row never learns
// which kind it holds.
//
// ``bind(candidateKey:toVideoID:)`` is what joins the two halves: from that moment the
// candidate key ALIASES the video id, so the `.resolving` status written before the
// resolve is readable through the video id, and every queue event that arrives after it
// — addressed by the video id, which is the only name the download queue has ever known
// — is readable through the candidate key the table is still rendering. Storing the
// status under ONE canonical key (rather than mirroring it into two) is what makes that
// true in both directions for free.
//
// ── NEVER PERSISTED ──────────────────────────────────────────────────────────
//
// Nothing here reaches `UserDefaults` or GRDB, by explicit epic guardrail. A status is
// only meaningful against a download queue that is itself never persisted and a chat
// transcript that does not survive a reset, so a restored status would describe a row
// that no longer exists. `KaraokeReadyStore` / `KaraokeQueueStore` are the shipped
// precedent for this discipline.
//
// This file imports only Foundation, Observation and Services. It MUST NOT import
// AppKit/UIKit, `URLSession`, or `Process` — `macOS/Sources/Downloads` is scanned
// wholesale by `scripts/check-downloader-boundary.sh`.
import Foundation
import Observation
import Services

// MARK: - The value a row renders

/// Where one chat suggestion's download currently stands.
///
/// Deliberately COARSER than ``DownloadState``: a row in a chat transcript reports a
/// phase, not an engine lifecycle, so speed and ETA are dropped and the typed failure
/// collapses to ``failed`` — the queue pane already renders those in full, per row.
enum ChatDownloadRowStatus: Equatable {
    /// Nothing has happened to this row. The default for any key never written.
    case none
    /// A candidate with no verified video is being looked up right now.
    case resolving
    /// No video could be attached to this song, so it can never be downloaded.
    ///
    /// Two different situations land here on purpose, because they are the same fact to
    /// a listener: the resolver had no confident answer, OR the session's lookup budget
    /// (`maxChatResolutionsPerSession`) was already spent, in which case no lookup was
    /// attempted at all.
    case notFound
    /// Download history already has this video. Advisory only — it never blocks a
    /// re-download, and a later ``queued`` overwrites it.
    case alreadyDownloaded
    /// Accepted into the download queue, waiting for the driver.
    case queued
    /// Bytes are moving. `fraction` is `0...1`, or `nil` while the phase is
    /// indeterminate (the metadata prefetch, or an unsized stream).
    case downloading(fraction: Double?)
    /// The transfer finished and the engine is extracting/transcoding/tagging.
    case converting
    /// The file landed. The terminal success for a download that was not bound for a
    /// playlist — and for one whose import was refused, since the download itself still
    /// succeeded.
    case downloaded
    /// The track is now a member of the named playlist. The terminal success for a
    /// chat-initiated download that WAS bound for one.
    ///
    /// `name` is empty when the playlist's name could not be read; the rendering side
    /// owns that fallback copy, exactly as the toast coalescer does.
    case addedToPlaylist(name: String)
    /// The download, the import, or the playlist append gave up.
    case failed
}

// MARK: - The policy

/// What one ``ChatDownloadAppendEvent`` does to a row's status.
///
/// Mirrors ``ChatDownloadToastDecision``'s shape: the mapping is a pure, total function
/// over the event vocabulary, and the one case that needs an asynchronous lookup is
/// carried OUT of the switch rather than making the whole mapping `async`.
enum ChatDownloadStatusEffect: Equatable {
    /// The row keeps whatever it already said — an expected intermediate state, or an
    /// outcome that changes nothing a listener is watching for.
    case unchanged
    /// The row becomes this status.
    case set(ChatDownloadRowStatus)
    /// The row becomes ``ChatDownloadRowStatus/addedToPlaylist(name:)`` once this
    /// playlist's display name has been resolved off the main actor.
    case addedToPlaylist(playlistId: Int64)
}

/// Maps the two engine vocabularies onto what a suggestion row says. Pure and total.
enum ChatDownloadStatusPolicy {
    /// Collapses a queue row's lifecycle state into a row status.
    ///
    /// `.fetchingMetadata` joins `.downloading` because both mean "this row is working
    /// and has not produced a file yet"; the prefetch simply reports no fraction, which
    /// ``DownloadState/fraction`` already answers as `nil`.
    ///
    /// `.cancelled` returns ``ChatDownloadRowStatus/none`` rather than a terminal
    /// status: a cancelled row is one the listener took back, and the offer to download
    /// it again must read exactly as it did before they first pressed the button.
    static func status(for state: DownloadState) -> ChatDownloadRowStatus {
        switch state {
        case .queued: .queued
        case .fetchingMetadata, .downloading: .downloading(fraction: state.fraction)
        case .postProcessing: .converting
        case .finished: .downloaded
        case .failed: .failed
        case .cancelled: .none
        }
    }

    /// The whole ``ChatDownloadAppendEvent`` vocabulary, EXHAUSTIVELY and with no
    /// `default` — a thirteenth case must break this build rather than fall silently
    /// into "the row keeps saying whatever it said", which is the one outcome a status
    /// column cannot recover from.
    ///
    /// The five ``unchanged`` cases are not oversights:
    ///   * `.heldForProposal` — the append is PARKED, not lost; the row is still
    ///     `.downloaded` and becomes `.addedToPlaylist` when the proposal is applied.
    ///   * `.alreadyInPlaylist` — the desired end state already holds.
    ///   * `.queueFull`, `.notRegisteredNoPlaylist`, `.skippedProfileChanged` — the
    ///     PLAYLIST link failed, but the file itself is on disk and the row's own
    ///     `.downloaded` remains the true report of what happened to it. The toast
    ///     coalescer says the rest, once, in a sentence.
    static func effect(for event: ChatDownloadAppendEvent) -> ChatDownloadStatusEffect {
        switch event {
        case let .appended(playlistId, _):
            .addedToPlaylist(playlistId: playlistId)
        // The import gate refused the file, so no scan ran — but the DOWNLOAD itself
        // succeeded, and that is what this row reports.
        case .gateFailed:
            .set(.downloaded)
        case .importFailed, .playlistMissing, .appendFailed, .alreadyDownloadedUnresolved, .appendAbandoned:
            .set(.failed)
        case .heldForProposal, .alreadyInPlaylist, .queueFull, .notRegisteredNoPlaylist, .skippedProfileChanged:
            .unchanged
        }
    }
}

// MARK: - The store

/// One status per suggestion row, folded from the queue, the progress seam, the append
/// pipeline and download history.
///
/// `@Observable` at DICTIONARY granularity, deliberately: every row's status lives in
/// one property, so a progress sample invalidates the whole table. That is the opposite
/// of ``DownloadRowLeaf``'s per-row object, and it is the right trade here — a chat
/// turn offers at most a few dozen rows of text, where the downloads pane renders N
/// live progress bars. Every write is equality-guarded anyway (`@Observable` fires on
/// same-value writes), so the steady stream of identical samples an unchanged phase
/// produces costs nothing.
@MainActor
@Observable
final class ChatDownloadStatusStore {
    /// Resolves a playlist's display name OFF the main actor.
    ///
    /// Injected rather than reached for: the repository read behind it has no `async`
    /// overload, so the composition root wraps it in `Task.detached`. Todo 9 hands this
    /// store the same closure ``ChatDownloadToastCoalescer`` receives — the coalescer
    /// keeps its own private copy and is untouched, so this is a second, independent
    /// hop rather than a shared cache neither type could invalidate.
    private let playlistName: @Sendable (Int64) async -> String?

    /// Status by CANONICAL key. A row bound to a video id is stored under that id; an
    /// unresolved candidate under its own `"q:"` key until ``bind(candidateKey:toVideoID:)``
    /// moves it.
    private var statuses: [String: ChatDownloadRowStatus] = [:]

    /// Candidate key → the video id it resolved to. One hop deep, and it can only ever
    /// be one hop: a video id is never itself a candidate key.
    private var aliases: [String: String] = [:]

    init(playlistName: @escaping @Sendable (Int64) async -> String?) {
        self.playlistName = playlistName
    }

    /// What `key` — a canonical video id OR a `"q:"` candidate key — currently says.
    ///
    /// A key this store has never been told about answers ``ChatDownloadRowStatus/none``,
    /// so the table can render every row without priming anything.
    func status(for key: String) -> ChatDownloadRowStatus {
        statuses[canonical(key)] ?? .none
    }

    /// A candidate's lookup has started.
    func markResolving(candidateKey: String) {
        set(.resolving, for: candidateKey)
    }

    /// A candidate's lookup produced nothing — or was never attempted, because the
    /// session's lookup budget was already spent.
    func markNotFound(candidateKey: String) {
        set(.notFound, for: candidateKey)
    }

    /// Joins a resolved candidate to the video id every later queue event will address
    /// it by.
    ///
    /// The candidate's own status is CARRIED ACROSS so the `.resolving` written a moment
    /// ago survives the join — unless the video id is already carrying a status of its
    /// own, in which case that one wins. A verified row and a candidate that resolved to
    /// the same video are the same download (the queue dedups them), and the one already
    /// in flight is the true report.
    func bind(candidateKey: String, toVideoID videoID: String) {
        guard candidateKey != videoID else { return }
        let carried = statuses[candidateKey]
        statuses[candidateKey] = nil
        aliases[candidateKey] = videoID
        if let carried, statuses[videoID] == nil {
            statuses[videoID] = carried
        }
    }

    /// Folds one queue snapshot in: pending rows are `.queued`, in-flight rows report
    /// their live phase.
    ///
    /// ADDITIVE, exactly like ``DownloadItemVideoIDMap/ingest(_:)``: a key absent from
    /// `snapshot` is left alone rather than cleared. A finished row leaves the queue
    /// immediately, so mirroring the snapshot would erase `.downloaded` the instant it
    /// became true.
    func ingest(_ snapshot: DownloadQueueSnapshot) {
        for item in snapshot.pendingItems {
            set(.queued, for: item.canonicalVideoID)
        }
        for item in snapshot.activeItems {
            set(ChatDownloadStatusPolicy.status(for: item.state), for: item.canonicalVideoID)
        }
    }

    /// Folds one progress sample in, turning the queue's `UUID` back into a row key.
    ///
    /// `videoID` is a PARAMETER rather than stored state so this store never retains the
    /// correlation map. Todo 9 passes `DownloadItemVideoIDMap.videoID(for:)`, whose
    /// retention contract is what makes a terminal sample work at all: that map
    /// ACCUMULATES and is pruned only by the terminal handler, AFTER it has resolved the
    /// id — so a `.finished` that arrives once the row has already left the snapshot
    /// still resolves here, provided this call stays BEFORE the prune in the chained
    /// progress closure.
    ///
    /// An id the map cannot resolve is not this store's row, so it is dropped.
    func apply(itemID: UUID, state: DownloadState, videoID: (UUID) -> String?) {
        guard let key = videoID(itemID) else { return }
        set(ChatDownloadStatusPolicy.status(for: state), for: key)
    }

    /// Folds one playlist-append event in.
    ///
    /// `videoID` is `nil` when the announcing site could not name the download the event
    /// belongs to; there is no row to update, so nothing happens.
    func apply(_ event: ChatDownloadAppendEvent, videoID: String?) async {
        guard let videoID else { return }
        switch ChatDownloadStatusPolicy.effect(for: event) {
        case .unchanged:
            return
        case let .set(status):
            set(status, for: videoID)
        case let .addedToPlaylist(playlistId):
            let name = await playlistName(playlistId) ?? ""
            set(.addedToPlaylist(name: name), for: videoID)
        }
    }

    /// Marks videos download history already knows about, WITHOUT overriding a row that
    /// is doing something.
    ///
    /// History is read once when a turn's suggestions appear, and the read hops off the
    /// main actor — so its answer can easily land after the listener has already pressed
    /// Download on one of those rows. "Already downloaded" would then overwrite a live
    /// `.queued`, and the row would look like nothing had happened.
    func markKnown(videoIDs: Set<String>) {
        for videoID in videoIDs where status(for: videoID) == .none {
            set(.alreadyDownloaded, for: videoID)
        }
    }

    /// Forgets every row and every alias. Called when the chat transcript is reset —
    /// the rows those statuses described are gone with it.
    func removeAll() {
        statuses.removeAll()
        aliases.removeAll()
    }
}

private extension ChatDownloadStatusStore {
    func canonical(_ key: String) -> String {
        aliases[key] ?? key
    }

    /// The single write path, equality-guarded because `@Observable` invalidates on
    /// same-value writes and the progress seam publishes several samples a second.
    ///
    /// A status is never sticky: the LAST thing that happened to a row is what it says,
    /// so a re-download reports `.queued` over a previous `.downloaded` — which is the
    /// whole reason there is no terminal latch here.
    func set(_ status: ChatDownloadRowStatus, for key: String) {
        let resolved = canonical(key)
        guard (statuses[resolved] ?? .none) != status else { return }
        statuses[resolved] = status
    }
}
