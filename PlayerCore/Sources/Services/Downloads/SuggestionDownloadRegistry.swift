// SuggestionDownloadRegistry — the in-memory linkage between a chat-initiated
// download and the playlist its finished track belongs in.
//
// A listener can ask for a suggested track while the playlist that will hold it does
// not exist yet: the model's proposal is still on screen, unapplied. That is the whole
// reason this type exists. It remembers, per canonical video id, WHICH targets are
// waiting for that download (`register`/`claimRegistrations`), and it parks track ids
// whose proposal has not been applied yet (`hold`/`resolveProposal`), so the append
// happens the moment the playlist acquires a real id rather than being dropped.
//
// Two shapes are load-bearing and neither is what a naive implementation would write:
//
//   * FAN-OUT. The registration store maps one video id to a LIST of targets, because
//     one download legitimately serves several at once (the same track suggested into
//     two playlists, or into a playlist and a pending proposal). A single-value map
//     would silently discard the earlier target — a lost append with no error anywhere.
//   * A NARROW rebuild sweep. ``evictAllPendingProposals()`` drops only the proposal
//     registrations and the held appends. `removeAll()` in its place would also throw
//     away valid in-flight `.playlist` registrations on a mere Intelligence toggle
//     flip, cancelling downloads-in-progress the listener never touched.
//
// NEVER PERSISTED. There is no `Codable` conformance, no store, and no settings key by
// design: a linkage only means something while both the download and the chat turn that
// asked for it are alive. A relaunch starts empty, and the queue it mirrors (which is
// itself never persisted) starts empty too, so the two can never disagree.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Where a finished chat-initiated download should be appended.
///
/// The `pendingProposal` case is the reason this is an enum rather than a playlist id:
/// at registration time the playlist may not exist yet, and the target has to survive
/// that gap without inventing an identifier.
public enum SuggestionAppendTarget: Equatable, Hashable, Sendable {
    /// A playlist the model proposed but the listener has not applied yet, named by the
    /// proposal's own identifier. Swapped for ``playlist(_:)`` once it resolves.
    case pendingProposal(UUID)
    /// A playlist that already exists, named by its database id.
    case playlist(Int64)

    /// The proposal this target names, or `nil` when it already names a real playlist.
    ///
    /// The one accessor both eviction paths filter on, so "is this waiting on a
    /// proposal" is asked in exactly one place.
    public var proposalId: UUID? {
        switch self {
        case let .pendingProposal(id): id
        case .playlist: nil
        }
    }
}

/// One target waiting on one download, scoped to the profile that asked for it.
///
/// Profile is part of the registration's IDENTITY, not decoration: the same playlist id
/// under two profiles is two distinct appends, so duplicate suppression compares both.
public struct SuggestionDownloadRegistration: Equatable, Hashable, Sendable {
    /// Where the finished track should land.
    public let target: SuggestionAppendTarget
    /// The profile that requested the download, captured at registration time so a
    /// profile switch mid-download cannot re-attribute the append.
    public let profileId: Int64

    public init(target: SuggestionAppendTarget, profileId: Int64) {
        self.target = target
        self.profileId = profileId
    }
}

/// The in-memory fan-out registry linking chat-initiated downloads to their append
/// targets, and parking appends whose proposal has not been applied yet.
///
/// `@MainActor` because every caller — the chat view model, the download completion
/// seam, and the proposal apply/discard actions — already runs there; an actor would
/// add hops to a bookkeeper whose whole workload is dictionary arithmetic.
///
/// Nothing here is persisted. See the file header for why.
@MainActor
public final class SuggestionDownloadRegistry {
    /// The most DISTINCT video ids the registry will track at once.
    ///
    /// Mirrors ``DownloadQueueLimits/maxQueueDepth`` deliberately: a registration only
    /// matters while its download is queued, so a registry that could outgrow the queue
    /// would be accumulating entries that can never be claimed. Fan-out is free against
    /// this cap — adding a target to an id already registered introduces no new key.
    public static let maxRegistrations = 1000

    /// Targets awaiting each canonical video id, in registration order.
    private var registrations: [String: [SuggestionDownloadRegistration]] = [:]

    /// The playlist id each applied proposal became.
    private var resolvedProposals: [UUID: Int64] = [:]

    /// Track ids downloaded before their proposal was applied, parked per proposal in
    /// arrival order until ``resolveProposal(_:playlistId:)`` flushes them.
    private var heldAppends: [UUID: [Int64]] = [:]

    /// Creates an empty registry. The composition root owns the single instance.
    public init() {}

    /// How many DISTINCT video ids currently have at least one registration.
    ///
    /// Not the number of registrations — a video registered for three targets counts
    /// once, because that is the quantity ``maxRegistrations`` bounds.
    public var count: Int {
        registrations.count
    }

    /// Records that a finished download of `videoID` should be appended to `target` for
    /// `profileId`.
    ///
    /// - Returns: `true` when the registration is stored, and also when it was an exact
    ///   duplicate of one already present (the caller's intent is satisfied either way).
    ///   `false` when the id is empty, or when it is a NEW id and the registry already
    ///   holds ``maxRegistrations`` distinct ids — the caller should report that the
    ///   link could not be made rather than assume it was.
    ///
    /// An empty id is refused outright: nothing can ever claim it back, so storing one
    /// would be an unreachable entry occupying a cap slot.
    @discardableResult
    public func register(videoID: String, target: SuggestionAppendTarget, profileId: Int64) -> Bool {
        guard !videoID.isEmpty else { return false }
        let registration = SuggestionDownloadRegistration(target: target, profileId: profileId)
        guard var existing = registrations[videoID] else {
            guard registrations.count < Self.maxRegistrations else { return false }
            registrations[videoID] = [registration]
            return true
        }
        guard !existing.contains(registration) else { return true }
        existing.append(registration)
        registrations[videoID] = existing
        return true
    }

    /// Removes and returns every target waiting on `videoID`, in registration order.
    ///
    /// Destructive by design — a download completes once, so the registration has no
    /// second use and leaving it behind would re-append on any later completion for the
    /// same id. A `.pendingProposal` target whose proposal has since resolved is
    /// returned already swapped for the `.playlist(id)` it became, so the caller never
    /// has to consult the resolution table itself.
    public func claimRegistrations(videoID: String) -> [SuggestionDownloadRegistration] {
        guard let claimed = registrations.removeValue(forKey: videoID) else { return [] }
        return claimed.map(resolving)
    }

    /// Parks `trackId` until `proposal` is applied and has a real playlist id.
    public func hold(trackId: Int64, forProposal proposal: UUID) {
        heldAppends[proposal, default: []].append(trackId)
    }

    /// The track ids currently parked for `proposal`, in hold order.
    ///
    /// A read-only inspection hook — ``resolveProposal(_:playlistId:)`` is what actually
    /// consumes them.
    public func heldTrackIds(forProposal proposal: UUID) -> [Int64] {
        heldAppends[proposal] ?? []
    }

    /// Records that `proposal` became the playlist `playlistId`, and flushes everything
    /// parked for it.
    ///
    /// - Returns: the parked track ids in hold order, or `[]` when nothing was parked
    ///   (including on a repeat call — the first one already drained them).
    ///
    /// Idempotent under retry, with the NEWEST id winning: applying a proposal twice
    /// (a failed first attempt, then a successful one) yields two different playlist
    /// ids, and later claims must target the playlist that actually exists — the second
    /// one. An older id is never restored.
    @discardableResult
    public func resolveProposal(_ proposal: UUID, playlistId: Int64) -> [Int64] {
        resolvedProposals[proposal] = playlistId
        return heldAppends.removeValue(forKey: proposal) ?? []
    }

    /// The playlist `proposal` resolved to, or `nil` when it has not been applied here.
    ///
    /// The fallback for a registration that arrives after the proposal was applied and
    /// has already left the proposal store — the resolution outlives the proposal.
    public func resolvedPlaylistId(forProposal proposal: UUID) -> Int64? {
        resolvedProposals[proposal]
    }

    /// Drops every target waiting on `videoID`.
    public func evict(videoID: String) {
        registrations[videoID] = nil
    }

    /// The discard path: drops everything parked for `proposal` AND every registration
    /// aimed at it, emptying out any video id left with no targets.
    ///
    /// Co-registered targets on the same video survive — discarding a proposal must not
    /// cancel an unrelated playlist append riding the same download. The recorded
    /// resolution is deliberately NOT removed: a proposal that was applied and then
    /// discarded still has a real playlist that later registrations may name.
    public func evictAll(forProposal proposal: UUID) {
        heldAppends[proposal] = nil
        pruneRegistrations { $0.target.proposalId != proposal }
    }

    /// The rebuild-edge sweep: drops EVERY pending-proposal registration and ALL held
    /// appends, while leaving `.playlist(id)` registrations and recorded resolutions
    /// intact.
    ///
    /// Deliberately narrower than ``removeAll()``. The AI graph rebuilds on something as
    /// ordinary as toggling Intelligence, at which point every on-screen proposal is
    /// gone and its identifiers are unclaimable — but downloads already bound for a real
    /// playlist are still in flight and still correct.
    public func evictAllPendingProposals() {
        heldAppends.removeAll()
        pruneRegistrations { $0.target.proposalId == nil }
    }

    /// Clears registrations, held appends, and recorded resolutions alike.
    public func removeAll() {
        registrations.removeAll()
        resolvedProposals.removeAll()
        heldAppends.removeAll()
    }
}

private extension SuggestionDownloadRegistry {
    /// `registration` with a resolved `.pendingProposal` target swapped for the real
    /// playlist it became; returned unchanged otherwise.
    func resolving(_ registration: SuggestionDownloadRegistration) -> SuggestionDownloadRegistration {
        guard let proposal = registration.target.proposalId,
              let playlistId = resolvedProposals[proposal]
        else { return registration }
        return SuggestionDownloadRegistration(target: .playlist(playlistId), profileId: registration.profileId)
    }

    /// Keeps only the registrations satisfying `isKept`, dropping any video id left with
    /// none.
    ///
    /// `compactMapValues` rather than an in-place loop precisely for that last part: a
    /// key whose list empties must disappear, or ``count`` keeps counting a video that
    /// has nothing waiting on it — and that phantom occupies a ``maxRegistrations`` slot.
    func pruneRegistrations(_ isKept: (SuggestionDownloadRegistration) -> Bool) {
        registrations = registrations.compactMapValues { list in
            let kept = list.filter(isKept)
            return kept.isEmpty ? nil : kept
        }
    }
}
