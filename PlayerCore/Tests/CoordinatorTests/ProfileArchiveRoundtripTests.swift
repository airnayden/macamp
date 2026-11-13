// ProfileArchiveRoundtripTests — export → import into the SAME database.
//
// The headline assertion is byte-for-byte digest equality: when every archived
// identity matches a local track, the imported profile must be statistically
// indistinguishable from the source, `mostReplayed` included. Everything else here
// pins the three things import must REFUSE to carry across.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

@Suite("Profile archive roundtrip")
struct ProfileArchiveRoundtripTests {
    @Test("a same-database roundtrip reproduces the digest byte for byte")
    func roundtripDigestIsByteIdentical() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let before = try await archiveDigestJSON(database, profileId: sourceId)

        let archive = try await makeArchiveExporter(database)
            .makeArchive(profileId: sourceId, settings: ArchiveFixture.settings)
        let summary = try await makeArchiveImporter(database)
            .importArchive(archive, applyingSettingsAndEQPresets: false)

        let after = try await archiveDigestJSON(database, profileId: summary.profileId)
        #expect(after == before)
    }

    @Test("the roundtrip digest actually contains the facets it claims to preserve")
    func roundtripDigestIsNotVacuous() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let archive = try await makeArchiveExporter(database)
            .makeArchive(profileId: sourceId, settings: nil)
        let summary = try await makeArchiveImporter(database)
            .importArchive(archive, applyingSettingsAndEQPresets: false)

        let digest = try await makeDigestBuilder(database).buildDigest(profileId: summary.profileId)
        let allTime = try #require(digest.windows.first { $0.window == .allTime })
        #expect(allTime.totalPlays > 0)
        #expect(!allTime.topTracks.isEmpty)
        #expect(!allTime.topArtists.isEmpty)
        #expect(!allTime.topGenres.isEmpty)
        #expect(allTime.hourHistogram.reduce(0, +) > 0)
        #expect(digest.mostReplayed.count == 3)
    }

    @Test("import always creates a NEW profile and never touches the source")
    func importAllocatesANewProfile() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let archive = try await makeArchiveExporter(database)
            .makeArchive(profileId: sourceId, settings: nil)
        let summary = try await makeArchiveImporter(database)
            .importArchive(archive, applyingSettingsAndEQPresets: false)

        #expect(summary.profileId != sourceId)
        #expect(summary.profileId != ProfileRecord.guestID)
        let storedImported = try fetchProfile(database, id: summary.profileId)
        let imported = try #require(storedImported)
        let storedSource = try fetchProfile(database, id: sourceId)
        let source = try #require(storedSource)
        #expect(imported.name == ArchiveFixture.sourceProfileName)
        #expect(imported.lastName == ArchiveFixture.sourceProfileLastName)
        #expect(imported.bio == ArchiveFixture.sourceProfileBio)
        #expect(imported.avatarId == ArchiveFixture.sourceAvatarId)
        // The source keeps everything it had.
        #expect(source.avatarImagePath == ArchiveFixture.sourceAvatarImagePath)
        #expect(source.pinHash != nil)
    }

    @Test("the imported profile carries no avatar path, no PIN and no library roots")
    func importStripsMachineLocalState() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let archive = try await makeArchiveExporter(database)
            .makeArchive(profileId: sourceId, settings: nil)
        let summary = try await makeArchiveImporter(database)
            .importArchive(archive, applyingSettingsAndEQPresets: false)

        let storedImported = try fetchProfile(database, id: summary.profileId)

        let imported = try #require(storedImported)
        #expect(imported.avatarImagePath == nil)
        #expect(imported.pinHash == nil)
        #expect(imported.pinSalt == nil)
        let roots = try countRows(database, table: "libraryRoot", profileId: summary.profileId)
        #expect(roots == 0)
        let sourceRoots = try countRows(database, table: "libraryRoot", profileId: sourceId)
        #expect(sourceRoots == 1)
    }

    @Test("every statistics table is restored in full when all identities match")
    func importRestoresEveryStatisticsRow() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let archive = try await makeArchiveExporter(database)
            .makeArchive(profileId: sourceId, settings: nil)
        let summary = try await makeArchiveImporter(database)
            .importArchive(archive, applyingSettingsAndEQPresets: false)

        #expect(summary.importedEvents == ArchiveFixture.events.count)
        #expect(summary.importedRollups == 1)
        #expect(summary.importedSegmentHeat == ArchiveFixture.heatmaps.count)
        #expect(summary.unmatchedSegmentHeat == 0)
        #expect(summary.importedTrackStates == ArchiveFixture.tracks.count)
        #expect(summary.droppedTrackStates == 0)
        let events = try countRows(database, table: "playEvent", profileId: summary.profileId)
        #expect(events == ArchiveFixture.events.count)
        let states = try countRows(database, table: "profileTrackState", profileId: summary.profileId)
        #expect(states == ArchiveFixture.tracks.count)
        let violations = try foreignKeyViolationCount(database)
        #expect(violations == 0)
    }

    @Test("matched heatmaps attach to the real local tracks, never to a synthetic id")
    func matchedHeatKeepsRealTrackIds() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let archive = try await makeArchiveExporter(database)
            .makeArchive(profileId: sourceId, settings: nil)
        let summary = try await makeArchiveImporter(database)
            .importArchive(archive, applyingSettingsAndEQPresets: false)

        let ids = try fetchSegmentHeatTrackIds(database, profileId: summary.profileId)
        #expect(ids == ArchiveFixture.tracks.map(\.trackId).sorted())
    }

    @Test("a roundtrip through the FILE is identical to a roundtrip through the value")
    func fileRoundtripMatchesValueRoundtrip() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let before = try await archiveDigestJSON(database, profileId: sourceId)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(
            ProfileArchiveExporter.suggestedFileName(for: ArchiveFixture.sourceProfileName)
        )

        try await makeArchiveExporter(database)
            .export(profileId: sourceId, settings: ArchiveFixture.settings, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.lastPathComponent == "Alex.macampprofile")

        let summary = try await makeArchiveImporter(database)
            .importArchive(at: url, applyingSettingsAndEQPresets: false)
        let after = try await archiveDigestJSON(database, profileId: summary.profileId)
        #expect(after == before)
    }

    @Test("exporting an unknown profile throws a typed error")
    func exportingAnUnknownProfileThrows() async throws {
        let database = try AppDatabase.makeEmpty()
        await #expect(throws: ProfileArchiveError.profileNotFound(profileId: 9999)) {
            _ = try await makeArchiveExporter(database).makeArchive(profileId: 9999, settings: nil)
        }
    }
}
