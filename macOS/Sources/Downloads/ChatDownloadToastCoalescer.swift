// ChatDownloadToastCoalescer — what the listener is told about a batch of downloads the
// assistant started, and how often.
//
// ── WHY COALESCE AT ALL ──────────────────────────────────────────────────────
//
// `ChatDownloadAppendEvent` is announced ONCE PER TRACK. A chat turn that offers a
// dozen songs therefore produces a dozen `.appended` events within the seconds the
// transfers take, and a toast apiece is a strobe that says the same thing twelve times.
// `ToastManager` shows one bubble at a time, so eleven of those twelve would also be
// overwritten before they could be read — the listener would see the LAST one and learn
// nothing about the other eleven. One sentence naming the total is the honest report.
//
// ── A FIXED WINDOW, DELIBERATELY NOT A DEBOUNCE ──────────────────────────────
//
// The window OPENS on the first buffered event and closes ``window`` later; it is not
// re-armed by the events that follow. A debounce (reset on every event) starves: a slow
// steady trickle of appends — which is exactly what several parallel transfers of
// different lengths produce — keeps pushing the deadline out, and the summary arrives
// only once the whole batch is over, or never if one straggler keeps arriving. A fixed
// window bounds the wait at ``window`` from the first append and simply opens a second
// window for whatever lands after it.
//
// ── THE GATE GUIDANCE IS LATCHED, THE FAULTS ARE NOT ─────────────────────────
//
// `.gateFailed` is announced once per FINISHED FILE, and a batch that trips the gate
// trips it identically for every file — same switch, same folder, same fix. So the
// guidance sentence is latched for the life of the window and re-arms with it, the same
// per-drain shape `DownloadRecoveryPolicy` uses for its System Settings offer. The
// remaining faults are NOT latched: each one names a different thing that went wrong
// with a different track, and collapsing them would be the coalescer inventing a claim.
//
// ── THE SWITCH IS EXHAUSTIVE, AND THAT IS THE SAFETY NET ─────────────────────
//
// ``ChatDownloadToastPolicy/fault(_:)`` has no `default`. That is the whole reason
// `ChatDownloadAppendEvent` was declared in its own file (see its header): a thirteenth
// case must break THIS build rather than fall silently into "say nothing".
// ``ChatDownloadToastPolicy/decide(_:)`` DOES carry a `default`, and only because the
// two switches together exceed SwiftLint's `cyclomatic_complexity` ceiling — as its own
// doc comment records. The exhaustiveness net is `fault(_:)`, never `decide(_:)`.
//
// The emitter is injected rather than a `ToastManager` so a test can count the
// sentences it produced — `activeToast` alone cannot tell one toast from three, which
// is precisely the property this type exists to guarantee.
import Foundation
import Services

/// One sentence the coalescer decided to say.
struct ChatDownloadToast: Equatable {
    let text: String
    let icon: String
}

// MARK: - The decision

/// What one ``ChatDownloadAppendEvent`` earns.
enum ChatDownloadToastDecision: Equatable {
    /// Nothing at all, by design — an expected intermediate state or an outcome that
    /// already holds.
    case silent
    /// Counted into the window's summary for this playlist.
    case summary(playlistId: Int64)
    /// The import-gate guidance sentence, at most once per window.
    case gateGuidance
    /// Its own sentence, immediately.
    case fault(ChatDownloadToastFault)
}

/// A single-track fault worth one sentence of its own.
enum ChatDownloadToastFault: Equatable, CaseIterable {
    case queueFull
    case noPlaylist
    case playlistMissing
    case unresolved
    case profileChanged
    case abandoned
    /// The playlist was there and the membership write still did not land — which
    /// ``ChatDownloadPlaylistAppender`` also reports when the existence probe or the
    /// membership read throws, so the copy stays about the outcome rather than the
    /// mechanism.
    case appendFailed
    case importFailed

    var message: LocalizedStringResource {
        switch self {
        case .queueFull: MacAMPStrings.chatDownloadQueueFullToast
        case .noPlaylist: MacAMPStrings.chatDownloadNoPlaylistToast
        case .playlistMissing: MacAMPStrings.chatDownloadPlaylistMissingToast
        case .unresolved: MacAMPStrings.chatDownloadUnresolvedToast
        case .profileChanged: MacAMPStrings.chatDownloadProfileChangedToast
        case .abandoned: MacAMPStrings.chatDownloadAbandonedToast
        case .appendFailed: MacAMPStrings.chatDownloadAppendFailedToast
        case .importFailed: MacAMPStrings.chatDownloadImportFailedToast
        }
    }

    var icon: String {
        "exclamationmark.triangle.fill"
    }
}

/// Maps the append vocabulary onto what the listener reads. Pure and total.
enum ChatDownloadToastPolicy {
    static func decide(_ event: ChatDownloadAppendEvent) -> ChatDownloadToastDecision {
        switch event {
        case let .appended(playlistId, _): .summary(playlistId: playlistId)
        // The append is PARKED, not lost: the summary arrives when applying the
        // proposal flushes it. Saying anything now would report a non-event.
        case .heldForProposal: .silent
        // The desired end state already holds, so there is nothing to report — the
        // track is in the playlist, which is what was asked for.
        case .alreadyInPlaylist: .silent
        case .gateFailed: .gateGuidance
        default: fault(event).map(ChatDownloadToastDecision.fault) ?? .silent
        }
    }

    /// The eight single-fault cases, split out of ``decide(_:)`` only because the two
    /// switches together exceed SwiftLint's `cyclomatic_complexity` ceiling.
    ///
    /// It stays EXHAUSTIVE with no `default`, which is what preserves the safety net a
    /// `default` in the caller would otherwise have removed: a thirteenth
    /// `ChatDownloadAppendEvent` case breaks the build HERE, and must be given either a
    /// fault or an explicit `nil` before it can ship.
    private static func fault(_ event: ChatDownloadAppendEvent) -> ChatDownloadToastFault? {
        switch event {
        case .importFailed: .importFailed
        case .playlistMissing: .playlistMissing
        case .appendFailed: .appendFailed
        case .skippedProfileChanged: .profileChanged
        case .alreadyDownloadedUnresolved: .unresolved
        case .appendAbandoned: .abandoned
        case .queueFull: .queueFull
        case .notRegisteredNoPlaylist: .noPlaylist
        case .appended, .heldForProposal, .alreadyInPlaylist, .gateFailed: nil
        }
    }
}

// MARK: - The emitter

/// Buffers per-track append events into one sentence per playlist per window.
@MainActor
final class ChatDownloadToastCoalescer {
    /// How long a window stays open. Two seconds is long enough for a handful of
    /// parallel transfers to land together and short enough that the summary still
    /// reads as a response to what the listener just asked for.
    static let defaultWindow: Duration = .seconds(2)

    private let emit: @MainActor (ChatDownloadToast) -> Void
    private let playlistName: @Sendable (Int64) async -> String?
    private let window: Duration

    /// Appended tracks per playlist for the open window.
    private var appended: [Int64: Int] = [:]
    /// Whether this window has already spent its one guidance sentence.
    private var guidanceSpent = false
    private var closing: Task<Void, Never>?

    /// - Parameters:
    ///   - emit: says one sentence. Injected so a suite can count them.
    ///   - playlistName: resolves a playlist's display name OFF the main actor — the
    ///     repository read behind it has no async overload, so the composition root
    ///     wraps it in `Task.detached`. `nil` when it could not be read.
    ///   - window: how long a summary window stays open.
    init(
        emit: @escaping @MainActor (ChatDownloadToast) -> Void,
        playlistName: @escaping @Sendable (Int64) async -> String?,
        window: Duration = ChatDownloadToastCoalescer.defaultWindow
    ) {
        self.emit = emit
        self.playlistName = playlistName
        self.window = window
    }

    func record(_ event: ChatDownloadAppendEvent) {
        switch ChatDownloadToastPolicy.decide(event) {
        case .silent:
            return
        case let .summary(playlistId):
            appended[playlistId, default: 0] += 1
            openWindow()
        case .gateGuidance:
            openWindow()
            guard !guidanceSpent else { return }
            guidanceSpent = true
            emit(ChatDownloadToast(
                text: String(localized: MacAMPStrings.chatDownloadGateGuidanceToast),
                icon: "exclamationmark.triangle.fill"
            ))
        case let .fault(fault):
            emit(ChatDownloadToast(text: String(localized: fault.message), icon: fault.icon))
        }
    }

    /// Waits for the open window to close, so a suite can assert on the summary without
    /// sleeping for ``window``. Returns immediately when no window is open.
    func waitForPendingWindow() async {
        await closing?.value
    }
}

private extension ChatDownloadToastCoalescer {
    func openWindow() {
        guard closing == nil else { return }
        closing = Task { [weak self, window] in
            try? await Task.sleep(for: window)
            await self?.closeWindow()
        }
    }

    /// Says one sentence per playlist that gained tracks, then re-arms.
    ///
    /// The window is released FIRST: resolving the names suspends, and an append that
    /// lands during that suspension belongs to the next window rather than to a batch
    /// whose sentence is already being written.
    func closeWindow() async {
        closing = nil
        guidanceSpent = false
        let batch = appended
        appended.removeAll()
        for playlistId in batch.keys.sorted() {
            guard let count = batch[playlistId] else { continue }
            let name = await playlistName(playlistId)
            emit(ChatDownloadToast(text: Self.summaryText(count: count, playlist: name), icon: "text.badge.plus"))
        }
    }

    static func summaryText(count: Int, playlist: String?) -> String {
        guard let playlist, !playlist.isEmpty else {
            return MacAMPStrings.chatDownloadAddedUnnamedToast(count)
        }
        return MacAMPStrings.chatDownloadAddedToast(count, playlist: playlist)
    }
}
