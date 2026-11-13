import Foundation
import Persistence
import Services
import Testing

/// The three analyzers against a scripted library: what they must find, what they
/// must NOT find, and the two bounds that keep them from ever becoming a full scan.
@Suite("Library hygiene analyzers")
struct LibraryHygieneServiceTests {
    @Test("Twenty tracks with three planted issues yield exactly three findings")
    func plantedLibraryYieldsThreeFindings() async throws {
        let fixture = try LibraryHygieneFixture(membership: [1, 3, 4])
        try fixture.insert(LibraryHygieneFixture.plantedLibrary())

        let findings = try await fixture.service().findings(
            profileId: LibraryHygieneFixture.profileId,
            limit: 50
        )

        #expect(findings.count == 3)
        #expect(findings.duplicates.count == 1)
        #expect(findings.clusters.count == 1)
        #expect(findings.gaps.count == 1)
    }

    @Test("The same recording in two files groups; near misses do not")
    func duplicatePairGroupsAndNearMissesDoNot() async throws {
        let fixture = try LibraryHygieneFixture()
        try fixture.insert(LibraryHygieneFixture.plantedLibrary())

        let groups = try await fixture.service().duplicateGroups(
            profileId: LibraryHygieneFixture.profileId,
            limit: 50
        )

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        // The keeper is the lowest id — the row the library has held longest.
        #expect(group.canonical.trackId == 3)
        #expect(group.duplicates.map(\.trackId) == [4])
        // 12/13 differ by 13 s and 14/15 by 33% of file size, so neither is grouped
        // even though both pairs agree on normalized title and artist.
        #expect(!group.trackIds.contains(12))
        #expect(!group.trackIds.contains(14))
    }

    @Test("A duplicate proposes dropping the redundant membership, never a file")
    func duplicateGroupProposesPlaylistCleanupOnly() async throws {
        let fixture = try LibraryHygieneFixture(membership: [1, 3, 4])
        try fixture.insert(LibraryHygieneFixture.plantedLibrary())

        let groups = try await fixture.service().duplicateGroups(
            profileId: LibraryHygieneFixture.profileId,
            limit: 50
        )

        let cleanup = try #require(groups.first?.playlistCleanups.first)
        #expect(cleanup.playlistId == LibraryHygieneFixture.playlistId)
        #expect(cleanup.currentTrackIds == [1, 3, 4])
        // The FIRST-positioned member survives, in place; only the repeat is dropped.
        #expect(cleanup.proposedTrackIds == [1, 3])
        #expect(cleanup.removedCount == 1)
        // Reading findings must never write anything.
        #expect(fixture.playlists.recording.mutationCount == 0)
    }

    @Test("A duplicate outside every playlist has nothing to clean up")
    func duplicateWithNoMembershipHasNoCleanup() async throws {
        let fixture = try LibraryHygieneFixture()
        try fixture.insert(LibraryHygieneFixture.plantedLibrary())

        let groups = try await fixture.service().duplicateGroups(
            profileId: LibraryHygieneFixture.profileId,
            limit: 50
        )

        #expect(groups.first?.playlistCleanups.isEmpty == true)
    }

    @Test("Genre spelling variants collapse onto the majority spelling")
    func genreClusterCollapsesToMajoritySpelling() async throws {
        let fixture = try LibraryHygieneFixture()
        try fixture.insert(LibraryHygieneFixture.plantedLibrary())

        let clusters = try await fixture.service().genreClusters(
            profileId: LibraryHygieneFixture.profileId,
            limit: 50
        )

        #expect(clusters.count == 1)
        let cluster = try #require(clusters.first)
        #expect(cluster.canonicalGenre == "Hip-Hop")
        #expect(cluster.canonicalTrackCount == 2)
        #expect(cluster.variants.map(\.genre) == ["hip hop"])
        // Only the minority spelling is retagged — the majority is counted, not rewritten.
        #expect(cluster.tracksToRetag.map(\.trackId) == [8])
    }

    @Test("A gap names every missing field and suggests only the album artist")
    func metadataGapNamesMissingFields() async throws {
        let fixture = try LibraryHygieneFixture()
        try fixture.insert(LibraryHygieneFixture.plantedLibrary())

        let gaps = try await fixture.service().metadataGaps(
            profileId: LibraryHygieneFixture.profileId,
            limit: 50
        )

        #expect(gaps.count == 1)
        let gap = try #require(gaps.first)
        #expect(gap.track.trackId == 10)
        #expect(gap.missingFields == [.genre, .year, .albumArtist])
        // Year and genre have no local evidence, so nothing is invented for them.
        #expect(gap.suggestedAlbumArtist == "Gap Artist")
        #expect(gap.isActionable)
    }

    @Test("Missing and external-offline rows never surface in any finding")
    func unavailableTracksNeverSurface() async throws {
        let fixture = try LibraryHygieneFixture(membership: [1, 2])
        try fixture.insert(LibraryHygieneFixture.unavailableLibrary())
        let service = fixture.service()
        let profileId = LibraryHygieneFixture.profileId

        let groups = try await service.duplicateGroups(profileId: profileId, limit: 50)
        let clusters = try await service.genreClusters(profileId: profileId, limit: 50)
        let gaps = try await service.metadataGaps(profileId: profileId, limit: 50)

        #expect(groups.isEmpty)
        #expect(clusters.isEmpty)
        #expect(gaps.isEmpty)
    }

    @Test("A pristine library finds nothing and writes nothing")
    func pristineLibraryFindsNothingAndWritesNothing() async throws {
        let fixture = try LibraryHygieneFixture(membership: [1, 2, 3])
        try fixture.insert(LibraryHygieneFixture.pristineLibrary())

        let findings = try await fixture.service().findings(
            profileId: LibraryHygieneFixture.profileId,
            limit: 50
        )

        #expect(findings.isEmpty)
        let recording = fixture.playlists.recording
        #expect(recording.mutationCount == 0)
        #expect(recording.reorderCalls.isEmpty)
        #expect(recording.addTrackCalls.isEmpty)
        #expect(recording.removeTrackCalls.isEmpty)
    }

    @Test("Output is capped at the ceiling however large a limit is asked for")
    func outputIsBounded() async throws {
        let fixture = try LibraryHygieneFixture()
        try fixture.insert(LibraryHygieneFixture.gapLibrary(count: 120))

        let gaps = try await fixture.service(pageSize: 50).metadataGaps(
            profileId: LibraryHygieneFixture.profileId,
            limit: 10000
        )

        #expect(gaps.count == LibraryHygieneService.maxFindings)
    }

    @Test("Findings do not depend on the page size the walk uses")
    func findingsDoNotDependOnPageSize() async throws {
        let fixture = try LibraryHygieneFixture(membership: [1, 3, 4])
        try fixture.insert(LibraryHygieneFixture.plantedLibrary())
        let profileId = LibraryHygieneFixture.profileId

        let tiny = try await fixture.service(pageSize: 3).findings(profileId: profileId, limit: 50)
        let large = try await fixture.service(pageSize: 500).findings(profileId: profileId, limit: 50)

        #expect(tiny == large)
        #expect(tiny.count == 3)
    }
}

// MARK: - Reading a finding list

private extension [HygieneFinding] {
    var duplicates: [DuplicateGroup] {
        compactMap { finding in
            guard case let .duplicate(group) = finding else { return nil }
            return group
        }
    }

    var clusters: [GenreCluster] {
        compactMap { finding in
            guard case let .genreCluster(cluster) = finding else { return nil }
            return cluster
        }
    }

    var gaps: [MetadataGap] {
        compactMap { finding in
            guard case let .metadataGap(gap) = finding else { return nil }
            return gap
        }
    }
}
