// ProfileArchiveImportTests — importing onto a DIFFERENT machine.
//
// The target database here is built so that its rowids DELIBERATELY COLLIDE with the
// source's: ids 1–3 hold unrelated decoy songs, and the two songs that really do
// match sit at 4 and 5. Any implementation that trusted the archive's original ids
// would attach three heatmaps to three wrong songs and still "pass" a naive test —
// so the assertions below check the ids, not just the counts.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

@Suite("Profile archive cross-machine import")
struct ProfileArchiveImportTests {
    /// Decoys at 1–3 (the source's ids), the real matches at 4–5. `Song C` is absent
    /// on purpose: its counter row must be dropped and its heatmap must land on a
    /// synthetic negative id.
    static func makeTargetDatabase() throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try insertArchiveTracks(database, [
            ArchiveTrackSeed(trackId: 1, title: "Decoy One", artist: "Nobody", album: "Nowhere", duration: 111),
            ArchiveTrackSeed(trackId: 2, title: "Decoy Two", artist: "Nobody", album: "Nowhere", duration: 122),
            ArchiveTrackSeed(trackId: 3, title: "Decoy Three", artist: "Nobody", album: "Nowhere", duration: 133),
            ArchiveTrackSeed(
                trackId: 4,
                title: ArchiveFixture.songA.title,
                artist: ArchiveFixture.songA.artist,
                album: ArchiveFixture.songA.album,
                duration: ArchiveFixture.songA.duration
            ),
            ArchiveTrackSeed(
                trackId: 5,
                title: ArchiveFixture.songB.title,
                artist: ArchiveFixture.songB.artist,
                album: ArchiveFixture.songB.album,
                duration: ArchiveFixture.songB.duration
            ),
        ])
        return database
    }

    static func exportFixture() async throws -> (archive: ProfileArchive, digest: Data) {
        let source = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(source)
        let digest = try await archiveDigestJSON(source, profileId: sourceId)
        let archive = try await makeArchiveExporter(source)
            .makeArchive(profileId: sourceId, settings: ArchiveFixture.settings)
        return (archive, digest)
    }

    @Test("snapshot-sourced digest facets survive an import onto colliding rowids")
    func crossMachineDigestIsByteIdentical() async throws {
        let exported = try await Self.exportFixture()
        let target = try Self.makeTargetDatabase()
        let summary = try await makeArchiveImporter(target)
            .importArchive(exported.archive, applyingSettingsAndEQPresets: false)

        let imported = try await archiveDigestJSON(target, profileId: summary.profileId)
        #expect(imported == exported.digest)
    }

    @Test("no heatmap is ever attached to an unrelated local track")
    func unmatchedHeatUsesSyntheticNegativeIds() async throws {
        let exported = try await Self.exportFixture()
        let target = try Self.makeTargetDatabase()
        let summary = try await makeArchiveImporter(target)
            .importArchive(exported.archive, applyingSettingsAndEQPresets: false)

        let ids = try fetchSegmentHeatTrackIds(target, profileId: summary.profileId)
        #expect(ids.count == ArchiveFixture.heatmaps.count)
        // The decoys own ids 1–3 on this machine; nothing may land on them.
        #expect(ids.allSatisfy { ![1, 2, 3].contains($0) })
        #expect(ids.filter { $0 > 0 }.sorted() == [4, 5])
        #expect(ids.count(where: { $0 < 0 }) == 1)
        #expect(summary.unmatchedSegmentHeat == 1)
    }

    @Test("unmatched counter rows are dropped and the drop count is reported")
    func unmatchedCounterRowsAreDroppedAndReported() async throws {
        let exported = try await Self.exportFixture()
        let target = try Self.makeTargetDatabase()
        let summary = try await makeArchiveImporter(target)
            .importArchive(exported.archive, applyingSettingsAndEQPresets: false)

        #expect(summary.importedTrackStates == 2)
        #expect(summary.droppedTrackStates == 1)
        let stored = try countRows(target, table: "profileTrackState", profileId: summary.profileId)
        #expect(stored == 2)
        let violations = try foreignKeyViolationCount(target)
        #expect(violations == 0)
    }

    @Test("events keep their full snapshot even when their track is unmatched")
    func unmatchedEventsKeepTheirSnapshot() async throws {
        let exported = try await Self.exportFixture()
        let target = try Self.makeTargetDatabase()
        let summary = try await makeArchiveImporter(target)
            .importArchive(exported.archive, applyingSettingsAndEQPresets: false)

        let rows = try fetchPlayEvents(target, profileId: summary.profileId, title: ArchiveFixture.songC.title)
        let songC = try #require(rows.first)
        #expect(songC.trackId == nil)
        #expect(songC.artistName == ArchiveFixture.songC.artist)
        #expect(songC.albumTitle == ArchiveFixture.songC.album)
        #expect(songC.genre == ArchiveFixture.songC.genre)

        let matched = try fetchPlayEvents(target, profileId: summary.profileId, title: ArchiveFixture.songA.title)
        #expect(!matched.isEmpty)
        #expect(matched.allSatisfy { $0.trackId == 4 })
    }

    @Test("importing twice yields two independent profiles")
    func repeatedImportsDoNotCollide() async throws {
        let exported = try await Self.exportFixture()
        let target = try Self.makeTargetDatabase()
        let importer = makeArchiveImporter(target)
        let first = try await importer.importArchive(exported.archive, applyingSettingsAndEQPresets: false)
        let second = try await importer.importArchive(exported.archive, applyingSettingsAndEQPresets: false)

        #expect(first.profileId != second.profileId)
        let firstHeat = try countRows(target, table: "playSegmentHeat", profileId: first.profileId)
        let secondHeat = try countRows(target, table: "playSegmentHeat", profileId: second.profileId)
        #expect(firstHeat == ArchiveFixture.heatmaps.count)
        #expect(secondHeat == ArchiveFixture.heatmaps.count)
        let violations = try foreignKeyViolationCount(target)
        #expect(violations == 0)
    }
}
