// ChatDownloadTerminalStateHandler — the failure half of the chat-download route: what
// happens to a registered playlist append when the download it was waiting on ends
// WITHOUT producing a file.
//
// The success half is ``ChatDownloadPlaylistAppender/handleFinished(videoID:fileURL:registrations:)``,
// driven by the finished seam. This type is driven by the progress seam and hands every
// terminal state to ``ChatDownloadFailurePolicy``, which is where the reasoning lives; the
// work here is the plumbing that reasoning needs — resolve the id, claim, recover or
// announce, release the correlation.
//
// ── `.ignore` TOUCHES NOTHING, AND THAT IS AN ORDERING CONTRACT ──────────────
//
// `.finished` classifies ``ChatDownloadFailurePolicy/Classification/ignore``, and this
// handler must leave BOTH the registry and the map exactly as they are for it. The
// finished seam runs next and needs the registration to claim and the correlation to
// resolve; a handler that "tidied up" on `.finished` would strip them out from under it
// and the append would silently never happen. Non-terminal states are ignored for the
// ordinary reason: the download has not finished failing yet.
//
// ── ONE NOTICE PER VIDEO, NEVER PER REGISTRATION ─────────────────────────────
//
// A download can legitimately serve several targets at once. Abandoning it is ONE thing
// that happened to the listener, so ``ChatDownloadAppendEvent/appendAbandoned`` is
// announced once for the whole claim — and not at all when the claim was empty, because a
// failure nobody was waiting on is not news and the queue row already renders its own
// error copy.
//
// ── THE MAP IS RELEASED ON EVERY TERMINAL STATE THAT GETS HERE ───────────────
//
// Every branch except `.ignore` ends in ``DownloadItemVideoIDMap/prune(_:)``, including
// the ones that found nothing to do. The correlation's only purpose was to answer this
// callback, and a terminal state arrives once per row.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Routes a download row's terminal state to the playlist append waiting on it.
///
/// `@MainActor` because every collaborator already is — the registry, the map, the
/// appender and the announcement sink — and because the seam that drives it fires there.
/// The one read that touches a database rides the injected ``historyFilePath`` closure,
/// which is async precisely so the composition root can route it off the main actor.
@MainActor
public final class ChatDownloadTerminalStateHandler {
    private let registry: SuggestionDownloadRegistry
    private let map: DownloadItemVideoIDMap
    private let appender: ChatDownloadPlaylistAppender
    private let historyFilePath: @Sendable (String) async -> String?
    private let announce: (ChatDownloadAppendEvent) -> Void

    /// - Parameter historyFilePath: The most recent recorded destination for a canonical
    ///   video id, or `nil` when the history has never seen it. Injected as a closure
    ///   rather than a repository so this type stays free of Persistence, and `async` so
    ///   the read never runs on the main actor — the shipped
    ///   ``DownloadHistoryRepositoryProviding/latestEntry(canonicalVideoID:)`` is already
    ///   async and needs no further hop.
    public init(
        registry: SuggestionDownloadRegistry,
        map: DownloadItemVideoIDMap,
        appender: ChatDownloadPlaylistAppender,
        historyFilePath: @escaping @Sendable (String) async -> String?,
        announce: @escaping (ChatDownloadAppendEvent) -> Void
    ) {
        self.registry = registry
        self.map = map
        self.appender = appender
        self.historyFilePath = historyFilePath
        self.announce = announce
    }

    /// Handles one `onItemProgress` emission.
    ///
    /// An id this map never saw returns immediately and changes NOTHING. That is the only
    /// honest answer: the handler cannot tell which video an unknown row was for, and
    /// evicting a guess would drop a registration belonging to a download that is still
    /// perfectly alive.
    public func handle(itemID: UUID, state: DownloadState) async {
        guard let videoID = map.videoID(for: itemID) else { return }
        switch ChatDownloadFailurePolicy.classify(state) {
        case .ignore:
            return
        case .evictSilently:
            registry.evict(videoID: videoID)
            map.prune(itemID)
        case .evictWithNotice:
            evictWithNotice(videoID: videoID, itemID: itemID)
        case .recoverViaHistory:
            await recover(videoID: videoID, itemID: itemID, state: state)
        }
    }
}

// MARK: - Branches

private extension ChatDownloadTerminalStateHandler {
    /// Claims the waiting targets and reports the abandonment once, when there were any.
    func evictWithNotice(videoID: String, itemID: UUID) {
        let registrations = registry.claimRegistrations(videoID: videoID)
        if !registrations.isEmpty {
            announce(.appendAbandoned)
        }
        map.prune(itemID)
    }

    /// Appends from whatever path the download history recorded for this video.
    ///
    /// The claim comes FIRST and its emptiness short-circuits the history read: with
    /// nothing waiting there is no append to make, and the lookup would be a database
    /// round-trip taken purely to discard its answer. Claiming before the `await` is also
    /// what makes a repeated terminal emission harmless — the claim is destructive, so the
    /// second pass finds nothing and announces nothing.
    ///
    /// The appender never claims for itself; it is handed the registrations. See its own
    /// header for why that asymmetry is the safety argument.
    func recover(videoID: String, itemID: UUID, state: DownloadState) async {
        let registrations = registry.claimRegistrations(videoID: videoID)
        guard !registrations.isEmpty else {
            map.prune(itemID)
            return
        }
        let filePath = await historyFilePath(videoID)
        await appender.recoverAlreadyDownloaded(
            videoID: videoID,
            historyFilePath: filePath,
            registrations: registrations,
            unresolvedEvent: Self.unresolvedEvent(for: state)
        )
        map.prune(itemID)
    }

    /// What to announce when the recovery path resolves no library row.
    ///
    /// Only the shape that literally said "already downloaded" gets
    /// ``ChatDownloadAppendEvent/alreadyDownloadedUnresolved``. Everything else reaching
    /// recovery is a ``DownloadError/downloadFailed``, and `exitOutcome` maps EVERY
    /// `ExitCode.downloadError` onto that one case — network errors and 403s included — so
    /// it is a plain failure and must say so with the generic notice.
    static func unresolvedEvent(for state: DownloadState) -> ChatDownloadAppendEvent {
        guard case .failed(.alreadyDownloaded) = state else { return .appendAbandoned }
        return .alreadyDownloadedUnresolved
    }
}
