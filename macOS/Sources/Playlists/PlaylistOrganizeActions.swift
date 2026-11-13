// PlaylistOrganizeActions — the four proposals behind ``PlaylistOrganizeMenu``.
//
// EVERY ITEM PROPOSES; NONE WRITES. Each action reads the playlist, asks
// ``AssistantViewModel`` for an ``AIProposal``, and puts it in the window's review
// sheet. The repository is reached only by that sheet's Apply button, so a mis-click
// in a menu can never change a listener's playlist.
//
// Split from ``PlaylistOrganizeMenu`` so each source stays under the SwiftLint
// file-length limit; the members are internal because the menu in the sibling file
// invokes them.
import Persistence
import Services
import SwiftUI
import ViewModels

// MARK: - Actions

extension PlaylistOrganizeMenu {
    /// Proposes dropping every entry this playlist lists twice.
    func organizeDeduplicate() {
        organize(emptyMessage: AIActionStrings.noDuplicates) { assistant, playlistId, profileId, tracks in
            assistant.proposeMembershipCleanup(
                playlistId: playlistId,
                tracks: tracks,
                profileId: profileId
            )
        }
    }

    /// Proposes a rise → peak → fall running order over the SAME tracks.
    ///
    /// The fallback message is `alreadyInOrder` because — every other outcome now
    /// carrying its own reason — a `nil` with `nothingToChange` can only mean the
    /// arc moved nothing.
    func organizeReorderByEnergy() {
        guard canReorderByEnergy else { return }
        organize(emptyMessage: AIActionStrings.alreadyInOrder) { assistant, playlistId, profileId, tracks in
            await assistant.proposeEnergyReorder(
                playlistId: playlistId,
                orderedTrackIds: tracks.compactMap(\.id),
                profileId: profileId
            )
        }
    }

    /// Proposes a name for the playlist, derived from what it actually holds.
    func organizeSuggestName() {
        let currentName = playlist.name
        organize(emptyMessage: AIActionStrings.nothingToPropose) { assistant, playlistId, profileId, tracks in
            await assistant.proposeRename(
                playlistId: playlistId,
                currentName: currentName,
                context: Self.namingContext(for: tracks),
                profileId: profileId
            )
        }
    }

    /// Proposes one new playlist per genre this playlist holds more than once.
    ///
    /// Several proposals at once, so the first opens the review sheet and a toast
    /// reports the rest — they stay in the store until the listener works through
    /// them or the app quits. A cluster of one is not a theme: splitting a track out
    /// on its own describes the playlist rather than reorganising it.
    func organizeSplitByTheme() {
        guard let assistant = environment.intelligence?.assistant else { return }
        let profileId = organizeProfileId
        let playlistName = playlist.name
        Task { @MainActor in
            let clusters = await Self.genreClusters(in: drainedTracks())
            guard !clusters.isEmpty else {
                environment.toast.show(text: String(localized: AIActionStrings.noThemes))
                return
            }
            var filed: [AIProposal] = []
            for cluster in clusters {
                let name = AIActionStrings.themeName(playlist: playlistName, genre: cluster.genre)
                let proposal = await assistant.proposeMix(
                    from: .rulesResult(trackIds: cluster.trackIds),
                    named: String(localized: name),
                    profileId: profileId,
                    targetCount: cluster.trackIds.count
                )
                if let proposal { filed.append(proposal) }
            }
            guard let first = filed.first else {
                environment.toast.show(text: String(localized: AIActionStrings.nothingToPropose))
                return
            }
            if filed.count > 1 {
                environment.toast.show(text: String(localized: AIActionStrings.themesProposed(count: filed.count)))
            }
            nav.pendingProposal = first
        }
    }
}

// MARK: - Shared plumbing

extension PlaylistOrganizeMenu {
    /// Runs one proposal-producing action end to end: drain, propose, present.
    ///
    /// Shared so all four items report a `nil` proposal identically and none of them
    /// can forget that it is a normal outcome rather than a silent failure. WHICH
    /// normal outcome comes from ``AssistantViewModel/lastUnavailability``, which
    /// every contextual proposer sets; `emptyMessage` is only the action-specific
    /// fallback for the one path that reports a failure through `lastError` instead.
    func organize(
        emptyMessage: LocalizedStringResource,
        producing propose: @escaping @MainActor (
            _ assistant: AssistantViewModel,
            _ playlistId: Int64,
            _ profileId: Int64,
            _ tracks: [TrackRecord]
        ) async -> AIProposal?
    ) {
        guard let playlistId = playlist.id, let assistant = environment.intelligence?.assistant else { return }
        let profileId = organizeProfileId
        Task { @MainActor in
            let tracks = await drainedTracks()
            let proposal = await propose(assistant, playlistId, profileId, tracks)
            guard let proposal else {
                let reason = Self.message(for: assistant.lastUnavailability, fallback: emptyMessage)
                environment.toast.show(text: String(localized: reason))
                return
            }
            nav.pendingProposal = proposal
        }
    }

    /// The sentence one unavailability reason deserves.
    ///
    /// The four energy-reorder outcomes the listener can act on differently —
    /// "too long", "not analysed enough", "already in order", "too short" — used to
    /// collapse into one "Nothing to suggest here yet", which told them nothing
    /// about which of the four had happened or whether anything would help.
    static func message(
        for reason: AIProposalUnavailability?,
        fallback: LocalizedStringResource
    ) -> LocalizedStringResource {
        switch reason {
        case .busy: AIActionStrings.actionBusy
        case let .selectionTooShort(minimum): AIActionStrings.tooShortToReorder(minimum: minimum)
        case let .selectionTooLong(limit): AIActionStrings.tooLongToReorder(limit: limit)
        case .insufficientAnalysis: AIActionStrings.notEnoughAnalyzed
        case .backendUnavailable: AIActionStrings.namingUnavailable
        case .nothingToChange, .none: fallback
        }
    }
}

// MARK: - Pure aggregates

extension PlaylistOrganizeMenu {
    /// Fewest tracks a genre needs before it is worth its own playlist.
    static var minimumThemeSize: Int {
        2
    }

    /// How many ranked names a naming context carries. Matches
    /// `AssistantNamingPrompt.maxRankedNames`, so the prompt never has to drop any.
    static var maxRankedNames: Int {
        5
    }

    /// The playlist's genres, each with the tracks carrying it, largest first.
    ///
    /// Buckets by ``GenreFolding/key(for:)`` so "Hip-Hop", "hip hop" and "HIPHOP"
    /// form ONE theme, and displays the first spelling encountered so the proposed
    /// name reads the way the listener's own tags do. Ties break on the display
    /// spelling: a `Dictionary` iterates in no defined order, so without a total
    /// order the same playlist would split differently on each run.
    static func genreClusters(in tracks: [TrackRecord]) -> [(genre: String, trackIds: [Int64])] {
        var buckets: [String: (genre: String, trackIds: [Int64])] = [:]
        for track in tracks {
            guard let trackId = track.id,
                  let key = GenreFolding.key(for: track.genre),
                  let display = track.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !display.isEmpty
            else { continue }
            buckets[key, default: (genre: display, trackIds: [])].trackIds.append(trackId)
        }
        return buckets.values
            .filter { $0.trackIds.count >= minimumThemeSize }
            .sorted { lhs, rhs in
                lhs.trackIds.count == rhs.trackIds.count
                    ? lhs.genre < rhs.genre
                    : lhs.trackIds.count > rhs.trackIds.count
            }
    }

    /// The aggregates the naming ladder names a playlist from.
    ///
    /// Genres and artists are ranked by track count with the same total order
    /// ``genreClusters(in:)`` uses, for the same reason.
    static func namingContext(for tracks: [TrackRecord]) -> PlaylistNamingContext {
        let genres = rankedCounts(tracks.compactMap(\.genre))
        let artists = rankedCounts(tracks.compactMap(\.artistName))
        return PlaylistNamingContext(
            trackCount: tracks.count,
            topGenres: Array(genres.prefix(maxRankedNames)),
            topArtists: Array(artists.prefix(maxRankedNames)),
            distinctArtistCount: artists.count,
            dominantDecade: dominantDecade(in: tracks)
        )
    }

    /// The decade at least half the dated tracks come from, or `nil`.
    ///
    /// A bare plurality is not enough: a playlist spanning four decades has a
    /// "most common" one that names nothing, and a wrong decade in a proposed name
    /// is worse than no decade at all.
    static func dominantDecade(in tracks: [TrackRecord]) -> Int? {
        let decades = tracks.compactMap(\.year).map { $0 - $0 % 10 }
        guard !decades.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for decade in decades {
            counts[decade, default: 0] += 1
        }
        let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let leader = ranked.first, leader.value * 2 >= decades.count else { return nil }
        return leader.key
    }

    private static func rankedCounts(_ values: [String]) -> [AssistantNameCount] {
        var counts: [String: Int] = [:]
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            counts[trimmed, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { AssistantNameCount(name: $0.key, count: $0.value) }
    }
}
