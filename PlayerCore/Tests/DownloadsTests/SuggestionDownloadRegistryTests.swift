// SuggestionDownloadRegistry coverage — the fan-out, the hold/flush pair, and the
// three eviction paths.
//
// Every assertion here is about MEMBERSHIP, not about downloading: the registry is a
// pure in-memory bookkeeper that survives no relaunch, so there is nothing to fake and
// nothing to stub. The cases that matter are the ones where a naive dictionary would
// quietly lose work — a second target for a video already registered (last-write-wins),
// a proposal resolved twice with different ids (first-write-wins), and the rebuild-edge
// hygiene sweep (`removeAll()` would drop valid in-flight `.playlist` registrations).
import Foundation
import Services
import Testing

@MainActor
@Suite("Suggestion download registry")
struct SuggestionDownloadRegistryTests {
    /// A canonical 11-character YouTube id, the shape `YouTubeURLNormalizer` emits.
    static let videoID = "dQw4w9WgXcQ"
    static let otherVideoID = "aBcDeFgHiJk"
    static let profileID: Int64 = 1

    // MARK: - Register and claim

    @Test("a registered video claims back exactly what was registered")
    func registerThenClaimRoundtrips() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        #expect(registry.register(
            videoID: Self.videoID,
            target: .pendingProposal(proposalID),
            profileId: Self.profileID
        ))
        #expect(registry.count == 1)

        let claimed = registry.claimRegistrations(videoID: Self.videoID)
        #expect(claimed == [
            SuggestionDownloadRegistration(target: .pendingProposal(proposalID), profileId: Self.profileID),
        ])
    }

    @Test("claiming removes the entry — a second claim returns nothing")
    func claimIsDestructive() {
        let registry = SuggestionDownloadRegistry()
        registry.register(videoID: Self.videoID, target: .playlist(7), profileId: Self.profileID)

        #expect(registry.claimRegistrations(videoID: Self.videoID).count == 1)
        #expect(registry.claimRegistrations(videoID: Self.videoID).isEmpty)
        #expect(registry.count == 0)
    }

    @Test("claiming a video that was never registered returns nothing")
    func claimingAnUnknownVideoIsEmpty() {
        let registry = SuggestionDownloadRegistry()
        #expect(registry.claimRegistrations(videoID: Self.videoID).isEmpty)
    }

    @Test("an exact duplicate registration is ignored rather than stored twice")
    func exactDuplicateIsIgnored() {
        let registry = SuggestionDownloadRegistry()

        #expect(registry.register(videoID: Self.videoID, target: .playlist(7), profileId: Self.profileID))
        #expect(registry.register(videoID: Self.videoID, target: .playlist(7), profileId: Self.profileID))

        #expect(registry.count == 1)
        #expect(registry.claimRegistrations(videoID: Self.videoID).count == 1)
    }

    /// The same playlist under two different profiles is NOT a duplicate — the
    /// registration's identity is `(target, profileId)`, not the target alone.
    @Test("the same target under a different profile is a distinct registration")
    func profileIsPartOfRegistrationIdentity() {
        let registry = SuggestionDownloadRegistry()

        registry.register(videoID: Self.videoID, target: .playlist(7), profileId: 1)
        registry.register(videoID: Self.videoID, target: .playlist(7), profileId: 2)

        #expect(registry.claimRegistrations(videoID: Self.videoID).count == 2)
    }

    // MARK: - Fan-out

    /// The load-bearing case: one video can serve several targets at once, so a second
    /// registration must APPEND. A dictionary keyed by video id with a single value
    /// would silently drop the first target here.
    @Test("one video registered for two targets claims BOTH, in registration order")
    func fanOutReturnsEveryTarget() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        registry.register(videoID: Self.videoID, target: .playlist(7), profileId: Self.profileID)
        registry.register(videoID: Self.videoID, target: .pendingProposal(proposalID), profileId: Self.profileID)

        #expect(registry.count == 1)
        #expect(registry.claimRegistrations(videoID: Self.videoID) == [
            SuggestionDownloadRegistration(target: .playlist(7), profileId: Self.profileID),
            SuggestionDownloadRegistration(target: .pendingProposal(proposalID), profileId: Self.profileID),
        ])
    }

    // MARK: - Proposal resolution

    @Test("a claim swaps a resolved proposal target for the playlist it became")
    func claimSwapsResolvedProposalForPlaylist() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        registry.register(
            videoID: Self.videoID,
            target: .pendingProposal(proposalID),
            profileId: Self.profileID
        )
        _ = registry.resolveProposal(proposalID, playlistId: 42)

        #expect(registry.claimRegistrations(videoID: Self.videoID) == [
            SuggestionDownloadRegistration(target: .playlist(42), profileId: Self.profileID),
        ])
    }

    @Test("an unresolved proposal target claims back unchanged")
    func claimLeavesUnresolvedProposalAlone() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        registry.register(
            videoID: Self.videoID,
            target: .pendingProposal(proposalID),
            profileId: Self.profileID
        )

        #expect(registry.claimRegistrations(videoID: Self.videoID) == [
            SuggestionDownloadRegistration(target: .pendingProposal(proposalID), profileId: Self.profileID),
        ])
    }

    @Test("resolving a proposal returns the held track ids in hold order and clears them")
    func resolveReturnsAndClearsHeldAppends() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        registry.hold(trackId: 11, forProposal: proposalID)
        registry.hold(trackId: 22, forProposal: proposalID)
        #expect(registry.heldTrackIds(forProposal: proposalID) == [11, 22])

        #expect(registry.resolveProposal(proposalID, playlistId: 42) == [11, 22])
        #expect(registry.heldTrackIds(forProposal: proposalID).isEmpty)
        #expect(registry.resolveProposal(proposalID, playlistId: 42).isEmpty)
    }

    @Test("holds for different proposals never mix")
    func holdsAreKeyedPerProposal() {
        let registry = SuggestionDownloadRegistry()
        let first = UUID()
        let second = UUID()

        registry.hold(trackId: 11, forProposal: first)
        registry.hold(trackId: 22, forProposal: second)

        #expect(registry.resolveProposal(first, playlistId: 1) == [11])
        #expect(registry.resolveProposal(second, playlistId: 2) == [22])
    }

    /// Apply-then-retry: a second resolution with a DIFFERENT playlist id is not an
    /// error — the newest id wins, so a registration claimed afterwards lands in the
    /// playlist that actually exists.
    @Test("resolving twice with different playlist ids lets the NEWEST id win")
    func resolvingTwiceLetsTheNewestIDWin() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        registry.register(
            videoID: Self.videoID,
            target: .pendingProposal(proposalID),
            profileId: Self.profileID
        )
        _ = registry.resolveProposal(proposalID, playlistId: 42)
        _ = registry.resolveProposal(proposalID, playlistId: 99)

        #expect(registry.resolvedPlaylistId(forProposal: proposalID) == 99)
        #expect(registry.claimRegistrations(videoID: Self.videoID) == [
            SuggestionDownloadRegistration(target: .playlist(99), profileId: Self.profileID),
        ])
    }

    @Test("the resolved-playlist accessor is nil until the proposal resolves")
    func resolvedPlaylistIDAccessorReportsResolution() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        #expect(registry.resolvedPlaylistId(forProposal: proposalID) == nil)
        _ = registry.resolveProposal(proposalID, playlistId: 42)
        #expect(registry.resolvedPlaylistId(forProposal: proposalID) == 42)
    }

    // MARK: - Eviction

    @Test("evicting a video drops its whole entry and leaves other videos alone")
    func evictVideoDropsOnlyThatEntry() {
        let registry = SuggestionDownloadRegistry()
        registry.register(videoID: Self.videoID, target: .playlist(7), profileId: Self.profileID)
        registry.register(videoID: Self.otherVideoID, target: .playlist(8), profileId: Self.profileID)

        registry.evict(videoID: Self.videoID)

        #expect(registry.count == 1)
        #expect(registry.claimRegistrations(videoID: Self.videoID).isEmpty)
        #expect(registry.claimRegistrations(videoID: Self.otherVideoID).count == 1)
    }

    /// The discard path. It drops the held appends AND every registration aimed at that
    /// proposal, but leaves co-registered `.playlist` targets on the same video intact —
    /// a discarded proposal must not cancel an unrelated in-flight playlist append.
    @Test("discarding a proposal drops its holds and its registrations, sparing the rest")
    func evictAllForProposalDropsOnlyThatProposal() {
        let registry = SuggestionDownloadRegistry()
        let discarded = UUID()
        let kept = UUID()

        registry.register(videoID: Self.videoID, target: .pendingProposal(discarded), profileId: Self.profileID)
        registry.register(videoID: Self.videoID, target: .playlist(7), profileId: Self.profileID)
        registry.register(videoID: Self.otherVideoID, target: .pendingProposal(kept), profileId: Self.profileID)
        registry.hold(trackId: 11, forProposal: discarded)
        registry.hold(trackId: 22, forProposal: kept)

        registry.evictAll(forProposal: discarded)

        #expect(registry.heldTrackIds(forProposal: discarded).isEmpty)
        #expect(registry.heldTrackIds(forProposal: kept) == [22])
        #expect(registry.claimRegistrations(videoID: Self.videoID) == [
            SuggestionDownloadRegistration(target: .playlist(7), profileId: Self.profileID),
        ])
        #expect(registry.claimRegistrations(videoID: Self.otherVideoID) == [
            SuggestionDownloadRegistration(target: .pendingProposal(kept), profileId: Self.profileID),
        ])
    }

    /// A video whose ONLY registration targeted the discarded proposal loses its key
    /// entirely, rather than lingering as an empty list that `count` would still count.
    @Test("a video left with no registrations after a discard drops out of the count")
    func evictAllForProposalDropsEmptiedVideoKeys() {
        let registry = SuggestionDownloadRegistry()
        let discarded = UUID()

        registry.register(videoID: Self.videoID, target: .pendingProposal(discarded), profileId: Self.profileID)
        registry.evictAll(forProposal: discarded)

        #expect(registry.count == 0)
    }

    @Test("discarding a proposal keeps its recorded resolution")
    func evictAllForProposalKeepsResolution() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        _ = registry.resolveProposal(proposalID, playlistId: 42)
        registry.evictAll(forProposal: proposalID)

        #expect(registry.resolvedPlaylistId(forProposal: proposalID) == 42)
    }

    /// The rebuild edge. `removeAll()` here would drop valid in-flight `.playlist`
    /// registrations on a mere Intelligence toggle flip, so the sweep is narrow by
    /// construction: pending-proposal registrations and held appends only.
    @Test("the rebuild sweep drops pending proposals but spares playlist registrations")
    func evictAllPendingProposalsSparesPlaylistTargets() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()
        let resolved = UUID()

        registry.register(videoID: Self.videoID, target: .pendingProposal(proposalID), profileId: Self.profileID)
        registry.register(videoID: Self.videoID, target: .playlist(7), profileId: Self.profileID)
        registry.register(videoID: Self.otherVideoID, target: .pendingProposal(proposalID), profileId: Self.profileID)
        registry.hold(trackId: 11, forProposal: proposalID)
        _ = registry.resolveProposal(resolved, playlistId: 42)

        registry.evictAllPendingProposals()

        #expect(registry.count == 1)
        #expect(registry.claimRegistrations(videoID: Self.videoID) == [
            SuggestionDownloadRegistration(target: .playlist(7), profileId: Self.profileID),
        ])
        #expect(registry.claimRegistrations(videoID: Self.otherVideoID).isEmpty)
        #expect(registry.heldTrackIds(forProposal: proposalID).isEmpty)
        #expect(registry.resolvedPlaylistId(forProposal: resolved) == 42)
    }

    @Test("removeAll clears registrations, holds, and resolutions alike")
    func removeAllClearsEverything() {
        let registry = SuggestionDownloadRegistry()
        let proposalID = UUID()

        registry.register(videoID: Self.videoID, target: .playlist(7), profileId: Self.profileID)
        registry.hold(trackId: 11, forProposal: proposalID)
        _ = registry.resolveProposal(proposalID, playlistId: 42)

        registry.removeAll()

        #expect(registry.count == 0)
        #expect(registry.claimRegistrations(videoID: Self.videoID).isEmpty)
        #expect(registry.heldTrackIds(forProposal: proposalID).isEmpty)
        #expect(registry.resolvedPlaylistId(forProposal: proposalID) == nil)
    }

    // MARK: - Malformed input

    /// An empty id can never be claimed back (nothing produces one), so storing it would
    /// be an unreachable leak against the cap. It is refused outright.
    @Test("an empty video id is refused and stores nothing")
    func emptyVideoIDIsRefused() {
        let registry = SuggestionDownloadRegistry()

        #expect(!registry.register(videoID: "", target: .playlist(7), profileId: Self.profileID))
        #expect(registry.count == 0)
        #expect(registry.claimRegistrations(videoID: "").isEmpty)
    }

    // MARK: - Cap

    /// Mirrors `DownloadQueueLimits.maxQueueDepth` discipline: the registry is bounded so
    /// a runaway caller cannot balloon it. The cap counts DISTINCT video ids — an id
    /// already registered may always gain another target, because fan-out adds no key.
    @Test("a new video id past the cap is refused, while fan-out onto an existing id still works")
    func capRefusesNewVideoIDsButNotFanOut() {
        let registry = SuggestionDownloadRegistry()
        for index in 0 ..< SuggestionDownloadRegistry.maxRegistrations {
            #expect(registry.register(
                videoID: "video-\(index)",
                target: .playlist(Int64(index)),
                profileId: Self.profileID
            ))
        }
        #expect(registry.count == SuggestionDownloadRegistry.maxRegistrations)

        #expect(!registry.register(videoID: "overflow", target: .playlist(1), profileId: Self.profileID))
        #expect(registry.count == SuggestionDownloadRegistry.maxRegistrations)
        #expect(registry.claimRegistrations(videoID: "overflow").isEmpty)

        #expect(registry.register(videoID: "video-0", target: .playlist(999), profileId: Self.profileID))
        #expect(registry.claimRegistrations(videoID: "video-0").count == 2)
    }

    @Test("the cap is a thousand, matching the download queue's own depth ceiling")
    func capValueIsPinned() {
        #expect(SuggestionDownloadRegistry.maxRegistrations == 1000)
        #expect(SuggestionDownloadRegistry.maxRegistrations == DownloadQueueLimits.maxQueueDepth)
    }
}
