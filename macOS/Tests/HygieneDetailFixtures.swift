// Fixtures for ``HygieneDetailModelTests``.
//
// Local rather than borrowed from `PlayerCoreTestSupport`: `macampMacTests` does not
// link that product (see `macOS/Project.swift`), and the same-shaped findings are a
// dozen lines. They deliberately MIRROR `AssistantViewModelHygieneTests`'
// `HygieneFindingFixture` — same ids, same spellings, same playlist — so the two
// suites describe one library rather than two.
import Foundation
import Services
import ViewModels

enum HygieneFixtures {
    static let profileId: Int64 = 1

    static func track(_ trackId: Int64, artist: String? = "Radiohead") -> HygieneTrack {
        HygieneTrack(
            trackId: trackId,
            filePath: "/Music/\(trackId).flac",
            title: "Paranoid Android",
            artistName: artist
        )
    }

    /// Ids 3 and 4. A `nil` `playlistId` is the finding that is worth READING and
    /// maps to no proposal: two copies on disk that no playlist plays twice.
    static func duplicateGroup(playlistId: Int64?) -> DuplicateGroup {
        DuplicateGroup(
            canonical: track(3),
            duplicates: [track(4)],
            playlistCleanups: playlistId.map { identifier in
                [
                    DuplicatePlaylistCleanup(
                        playlistId: identifier,
                        currentTrackIds: [1, 3, 4],
                        proposedTrackIds: [1, 3]
                    ),
                ]
            } ?? []
        )
    }

    /// "Hip-Hop" twice, "hip hop" once — only the latter is retagged.
    static func genreCluster() -> GenreCluster {
        GenreCluster(
            canonicalGenre: "Hip-Hop",
            canonicalTrackCount: 2,
            variants: [
                GenreVariant(genre: "hip hop", tracks: [track(8, artist: "Filler Artist")]),
            ]
        )
    }

    /// A `nil` `artist` is the gap with no derivable fix: nothing to copy an album
    /// artist from, so the mapping produces no patch.
    static func gap(_ trackId: Int64, artist: String?) -> MetadataGap {
        MetadataGap(
            track: HygieneTrack(
                trackId: trackId,
                filePath: "/Music/\(trackId).flac",
                title: "Untagged Demo",
                artistName: artist
            ),
            missingFields: [.genre, .year, .albumArtist],
            suggestedAlbumArtist: artist
        )
    }

    static func organize(playlistId: Int64, proposedTrackIds: [Int64]) -> AIProposal {
        AIProposal(
            profileId: profileId,
            kind: .organize(
                playlistId: playlistId,
                diff: PlaylistOrganizeDiff(
                    currentTrackIds: proposedTrackIds + [99],
                    proposedTrackIds: proposedTrackIds
                )
            )
        )
    }
}

/// A scriptable ``LibraryHygieneProviding`` that serves one canned list.
struct StubHygieneService: LibraryHygieneProviding {
    var findings: [HygieneFinding] = []
    var shouldFail = false

    func duplicateGroups(profileId _: Int64, limit: Int) async throws -> [DuplicateGroup] {
        try served(limit).compactMap { finding in
            guard case let .duplicate(group) = finding else { return nil }
            return group
        }
    }

    func genreClusters(profileId _: Int64, limit: Int) async throws -> [GenreCluster] {
        try served(limit).compactMap { finding in
            guard case let .genreCluster(cluster) = finding else { return nil }
            return cluster
        }
    }

    func metadataGaps(profileId _: Int64, limit: Int) async throws -> [MetadataGap] {
        try served(limit).compactMap { finding in
            guard case let .metadataGap(gap) = finding else { return nil }
            return gap
        }
    }

    func findings(profileId _: Int64, limit: Int) async throws -> [HygieneFinding] {
        try served(limit)
    }

    private func served(_ limit: Int) throws -> [HygieneFinding] {
        guard !shouldFail else { throw StubHygieneError.forcedFailure }
        return Array(findings.prefix(max(0, limit)))
    }
}

enum StubHygieneError: Error, Equatable {
    case forcedFailure
}
