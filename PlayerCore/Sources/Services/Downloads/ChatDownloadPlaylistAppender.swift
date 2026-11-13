// ChatDownloadPlaylistAppender — what happens to a chat-initiated download once the
// engine says it landed: gate → exactly ONE scan → lookup → append or hold.
//
// ── THE CALLER CLAIMS, THIS TYPE NEVER DOES ──────────────────────────────────
//
// `registrations` arrives already claimed off ``SuggestionDownloadRegistry``,
// synchronously, before any dispatch. That asymmetry is the whole safety argument. If
// this type claimed instead, the route would have to check membership, hand control to a
// `Task`, and claim after resuming — and in that window ordinary main-actor work
// (discarding a proposal, resetting the chat, a policy eviction) can empty the registry.
// The legacy import path would already have been suppressed on the strength of a
// registration that no longer exists, and the download would reach nothing at all. A
// silent no-import, with no error anywhere. Claiming first makes the claim itself the
// decision: an empty claim means the caller takes the legacy path and never calls here.
//
// ── EXACTLY ONE SCAN, AND THE SUMMARY IS ADVISORY ────────────────────────────
//
// One `scan(.files([url]))` per finished item, however many targets are waiting. Two
// registrations are not two imports — they are two appends of one row, and a
// per-registration scan would multiply filesystem work by the fan-out.
//
// The ``ScanSummary`` that scan returns is NOT the success condition. `skipped: 1,
// added: 0` is the COMMON case: `DownloadLibraryImporter` or the folder watcher very
// often imported the same file a moment earlier, and the scanner deduplicates by
// `filePath`. Success is step 5 — the lookup found a row — and nothing else.
//
// ── PATHS ARE PASSED VERBATIM ────────────────────────────────────────────────
//
// The URL reported by the download callback goes to the scanner and its `.path` goes to
// the lookup byte for byte. `track.filePath` is a UNIQUE key on the exact string the
// scanner stored; standardizing it here would file the row under `/private/var/…` and
// then fail to find it under `/var/…`. ``ChatDownloadImportGate`` is the ONLY place
// normalization happens, on copies it makes itself — see its header.
//
// This file imports Foundation and Persistence, and MUST NOT import AppKit/UIKit,
// Process, or URLSession (PlayerCore portability invariant + downloader boundary gate).
import Foundation
import Persistence

/// Drives a finished chat-initiated download into the playlist(s) waiting for it.
///
/// `@MainActor` because every collaborator already is: the registry, the announcement
/// sink, and the download-completion seam that calls in. Every database read and write
/// it performs is routed OFF the main actor explicitly — through the repository's async
/// overloads, or through `Task.detached` for the one read that has no async twin.
@MainActor
public final class ChatDownloadPlaylistAppender {
    private let registry: SuggestionDownloadRegistry
    private let scanner: any LibraryScanning
    private let isAutoImportEnabled: @Sendable () -> Bool
    private let libraryRoots: @Sendable (Int64) async -> [URL]
    private let activeProfileId: () -> Int64
    private let trackLookup: (String) async throws -> Int64?
    private let playlists: any PlaylistRepositoryProviding
    private let announce: (ChatDownloadAppendEvent) -> Void

    /// The tail of the append chain. Each append waits on its predecessor, so a
    /// membership check and the write it guards are never split by another append.
    private var appendChain: Task<Void, Never>?

    public init(
        registry: SuggestionDownloadRegistry,
        scanner: any LibraryScanning,
        isAutoImportEnabled: @escaping @Sendable () -> Bool,
        libraryRoots: @escaping @Sendable (Int64) async -> [URL],
        activeProfileId: @escaping () -> Int64,
        trackLookup: @escaping (String) async throws -> Int64?,
        playlists: any PlaylistRepositoryProviding,
        announce: @escaping (ChatDownloadAppendEvent) -> Void
    ) {
        self.registry = registry
        self.scanner = scanner
        self.isAutoImportEnabled = isAutoImportEnabled
        self.libraryRoots = libraryRoots
        self.activeProfileId = activeProfileId
        self.trackLookup = trackLookup
        self.playlists = playlists
        self.announce = announce
    }

    /// Runs the finish-side pipeline for one downloaded file.
    ///
    /// `videoID` is deliberately unread: the caller has already claimed `registrations`
    /// with it, so the id identifies the call rather than driving it. It stays in the
    /// signature because every call site names a download by id and a later diagnostic
    /// must not have to reshape the seam to get it.
    ///
    /// Order is profile guard FIRST, then gate, then scan. When EVERY registration is
    /// skipped for a profile mismatch there is nobody left to import for, so no scan
    /// runs at all — an import is work done on a listener's behalf, and at that point
    /// there is no such listener. Survivors necessarily share the active profile, so the
    /// gate needs only one roots read and runs exactly once.
    public func handleFinished(
        videoID _: String,
        fileURL: URL,
        registrations: [SuggestionDownloadRegistration]
    ) async {
        guard let eligible = profileMatches(in: registrations) else { return }
        let roots = await libraryRoots(eligible.profileId)
        guard ChatDownloadImportGate.isEligible(
            autoImportEnabled: isAutoImportEnabled(),
            fileURL: fileURL,
            libraryRoots: roots
        ) else {
            announce(.gateFailed)
            return
        }
        _ = await scanner.scan(.files([fileURL]))
        await route(
            filePath: fileURL.path,
            registrations: eligible.registrations,
            unresolvedEvent: .importFailed
        )
    }

    /// Appends track ids that were parked on a proposal, now that it has a real playlist.
    ///
    /// Goes through the same append path as everything else, so duplicate suppression,
    /// the deleted-playlist check, and the serialization all apply unchanged.
    public func flushHeldAppends(trackIds: [Int64], playlistId: Int64) async {
        for trackId in trackIds {
            await append(trackId: trackId, playlistId: playlistId)
        }
    }

    /// The recovery entry for a download that produced no new file.
    ///
    /// Appends from a path the download history already recorded, with NO scan — there is
    /// nothing new on disk, and rescanning an existing row would be work for its own
    /// sake. `unresolvedEvent` is injected because this type cannot see the failure shape
    /// that brought it here: the caller distinguishes "already downloaded, path did not
    /// resolve" from "download failed outright", and both land in the same branch here.
    public func recoverAlreadyDownloaded(
        videoID _: String,
        historyFilePath: String?,
        registrations: [SuggestionDownloadRegistration],
        unresolvedEvent: ChatDownloadAppendEvent
    ) async {
        guard let eligible = profileMatches(in: registrations) else { return }
        guard let historyFilePath else {
            announce(unresolvedEvent)
            return
        }
        await route(
            filePath: historyFilePath,
            registrations: eligible.registrations,
            unresolvedEvent: unresolvedEvent
        )
    }
}

// MARK: - Pipeline stages

private extension ChatDownloadPlaylistAppender {
    /// The registrations that still belong to the active profile, with that profile's id.
    struct ProfileMatch {
        let profileId: Int64
        let registrations: [SuggestionDownloadRegistration]
    }

    /// Drops registrations whose profile is no longer active, announcing one
    /// `.skippedProfileChanged` for each, and returns `nil` when nothing survives.
    ///
    /// An empty input also returns `nil` without announcing. The contract says the caller
    /// only dispatches a non-empty claim; if that is ever violated, the honest response
    /// to "append this for nobody" is to do nothing rather than import a file anyway.
    func profileMatches(in registrations: [SuggestionDownloadRegistration]) -> ProfileMatch? {
        guard !registrations.isEmpty else { return nil }
        let profileId = activeProfileId()
        var kept: [SuggestionDownloadRegistration] = []
        for registration in registrations {
            guard registration.profileId == profileId else {
                announce(.skippedProfileChanged)
                continue
            }
            kept.append(registration)
        }
        guard !kept.isEmpty else { return nil }
        return ProfileMatch(profileId: profileId, registrations: kept)
    }

    /// Resolves `filePath` to a library row and dispatches each waiting target.
    ///
    /// A thrown lookup is treated exactly like a `nil` one: from here both mean "this
    /// file is not a library row", and there is no recovery either way.
    func route(
        filePath: String,
        registrations: [SuggestionDownloadRegistration],
        unresolvedEvent: ChatDownloadAppendEvent
    ) async {
        guard let trackId = try? await trackLookup(filePath) else {
            announce(unresolvedEvent)
            return
        }
        for registration in registrations {
            switch registration.target {
            case let .pendingProposal(proposal):
                registry.hold(trackId: trackId, forProposal: proposal)
                announce(.heldForProposal(proposal))
            case let .playlist(playlistId):
                await append(trackId: trackId, playlistId: playlistId)
            }
        }
    }

    /// Queues one append behind every append already queued, and waits for it.
    ///
    /// `@MainActor` alone does not order these. Each append suspends twice (the existence
    /// probe and the membership read), and another append can start in either window —
    /// which is a check-then-act race: two appends of the same track both read "not a
    /// member" before either writes, and the track lands twice. Chaining each `Task`
    /// behind its predecessor closes the window and makes appends land in call order.
    func append(trackId: Int64, playlistId: Int64) async {
        let previous = appendChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performAppend(trackId: trackId, playlistId: playlistId)
        }
        appendChain = task
        await task.value
    }

    /// One membership write, with both pre-checks and a failure that never escapes.
    ///
    /// `fetchPlaylist(id:)` has no async overload, so it is wrapped in `Task.detached` —
    /// the ``AssistantViewModel`` rename precedent — rather than run on the main actor.
    /// Every other read and write here uses the repository's own async overload.
    ///
    /// Nothing throws out of this seam. The caller is a download-completion callback with
    /// no error channel, so a failed write is reported as an event and the remaining
    /// targets still get their turn.
    func performAppend(trackId: Int64, playlistId: Int64) async {
        let repository = playlists
        do {
            let playlist = try await Task.detached(priority: .utility) {
                try repository.fetchPlaylist(id: playlistId)
            }.value
            guard playlist != nil else {
                announce(.playlistMissing(playlistId))
                return
            }
            let alreadyMember = try await repository.containsTrack(playlistId: playlistId, trackId: trackId)
            guard !alreadyMember else {
                announce(.alreadyInPlaylist(playlistId: playlistId, trackId: trackId))
                return
            }
            try await repository.addTrack(trackId: trackId, toPlaylist: playlistId)
            announce(.appended(playlistId: playlistId, trackId: trackId))
        } catch {
            announce(.appendFailed(playlistId))
        }
    }
}
