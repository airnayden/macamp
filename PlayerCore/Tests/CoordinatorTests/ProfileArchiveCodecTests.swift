// ProfileArchiveCodecTests — the payload's own guarantees.
//
// Covers the three things that are cheap to get wrong and expensive to discover in
// the field: a leaked machine-local path, an archive from another build that will not
// decode, and a corrupt file that leaves half a profile behind.
import Foundation
import GRDB
import Models
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

@Suite("Profile archive codec")
struct ProfileArchiveCodecTests {
    static func minimalArchive(
        settings: PortableSettings? = nil,
        eqPresets: [ProfileArchiveEQPreset] = []
    ) -> ProfileArchive {
        ProfileArchive(
            profile: ProfileArchiveProfile(
                name: "Sam",
                avatarId: ProfileRecord.defaultAvatarID,
                createdAt: ArchiveFixture.createdAt
            ),
            settings: settings,
            eqPresets: eqPresets
        )
    }

    // MARK: - No path leaks

    @Test("the exported payload carries no file path and no machine-local directory")
    func exportedJSONLeaksNoPaths() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let archive = try await makeArchiveExporter(database)
            .makeArchive(profileId: sourceId, settings: ArchiveFixture.settings)
        let data = try archive.encodedJSON()
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("filePath"))
        #expect(!json.contains("avatarImagePath"))
        #expect(!json.contains("pinHash"))
        #expect(!json.contains("pinSalt"))
        #expect(!json.contains("karaokeCacheDirectoryPath"))
        #expect(!json.contains("/Music/"))
        #expect(!json.contains(ArchiveFixture.sourceLibraryRoot))
        #expect(!json.contains(ArchiveFixture.sourceAvatarImagePath))
        if let instrumentals = InstrumentalCacheLocation.defaultDirectory()?.path {
            #expect(!json.contains(instrumentals))
        }
        #expect(!json.contains(InstrumentalCacheLocation.applicationSupportSubpath))
    }

    // MARK: - Determinism

    @Test("encoding is deterministic and re-encoding decoded bytes reproduces them")
    func encodingIsDeterministic() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let exporter = makeArchiveExporter(database)
        let first = try await exporter.makeArchive(profileId: sourceId, settings: ArchiveFixture.settings)
        let second = try await exporter.makeArchive(profileId: sourceId, settings: ArchiveFixture.settings)
        let firstBytes = try first.encodedJSON()
        let secondBytes = try second.encodedJSON()
        #expect(secondBytes == firstBytes)

        let decoded = try ProfileArchive.decoded(from: firstBytes)
        let reEncoded = try decoded.encodedJSON()
        #expect(reEncoded == firstBytes)
        #expect(decoded == first)
    }

    @Test("the 400-byte heatmap blob survives the base64 round trip byte for byte")
    func heatBlobSurvivesEncoding() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let archive = try await makeArchiveExporter(database).makeArchive(profileId: sourceId, settings: nil)
        let decoded = try ProfileArchive.decoded(from: archive.encodedJSON())
        let heat = try #require(decoded.segmentHeat.first)
        #expect(heat.bucketCounts.count == PlaySegmentHeatRecord.bucketCountsByteCount)
        let buckets = try PlaySegmentHeatRecord.decodeBuckets(heat.bucketCounts)
        #expect(buckets == DigestFixture.chorusBuckets)
    }

    // MARK: - Decode tolerance

    @Test("an archive missing every optional section still decodes and imports")
    func decodeToleratesMissingSections() async throws {
        let json = """
        {"archiveVersion":1,"profile":{"avatarId":"waveform-vice","createdAt":1700000000,"name":"Sam"}}
        """
        let archive = try ProfileArchive.decoded(from: Data(json.utf8))
        #expect(archive.events.isEmpty)
        #expect(archive.rollups.isEmpty)
        #expect(archive.segmentHeat.isEmpty)
        #expect(archive.trackStates.isEmpty)
        #expect(archive.eqPresets.isEmpty)
        #expect(archive.settings == nil)

        let database = try AppDatabase.makeEmpty()
        let summary = try await makeArchiveImporter(database)
            .importArchive(archive, applyingSettingsAndEQPresets: true)
        let storedImported = try fetchProfile(database, id: summary.profileId)
        let imported = try #require(storedImported)
        #expect(imported.name == "Sam")
        #expect(summary.settings == nil)
    }

    @Test("unknown settings keys are ignored and missing ones stay nil")
    func settingsDecodeIsLossless() throws {
        let json = """
        {"archiveVersion":1,
         "profile":{"avatarId":"waveform-vice","createdAt":1700000000,"name":"Sam"},
         "settings":{"appearance":"light","futureFeatureEnabled":true,"karaokeCacheCapBytes":42},
         "somethingFromTheFuture":[1,2,3]}
        """
        let archive = try ProfileArchive.decoded(from: Data(json.utf8))
        let settings = try #require(archive.settings)
        #expect(settings.appearance == "light")
        #expect(settings.karaokeCacheCapBytes == 42)
        #expect(settings.gaplessEnabled == nil)
        #expect(settings.themePreset == nil)
    }

    @Test("an all-nil settings snapshot encodes as an empty object")
    func emptySettingsOmitEveryKey() throws {
        let data = try ProfileArchive.makeEncoder().encode(PortableSettings())
        #expect(String(data: data, encoding: .utf8) == "{}")
    }

    // MARK: - Typed failures

    @Test("bytes that are not an archive surface as a typed malformed error")
    func garbageBytesThrowMalformed() throws {
        #expect(throws: ProfileArchiveError.self) {
            _ = try ProfileArchive.decoded(from: Data("not an archive".utf8))
        }
    }

    @Test("a truncated archive surfaces as a typed malformed error")
    func truncatedArchiveThrowsMalformed() async throws {
        let database = try AppDatabase.makeEmpty()
        let sourceId = try seedArchiveFixture(database)
        let archive = try await makeArchiveExporter(database).makeArchive(profileId: sourceId, settings: nil)
        let full = try archive.encodedJSON()
        let truncated = full.prefix(full.count / 2)
        #expect(throws: ProfileArchiveError.self) {
            _ = try ProfileArchive.decoded(from: Data(truncated))
        }
    }

    @Test("an archive from a newer build is refused by version, not by parse failure")
    func futureVersionIsRefused() throws {
        var archive = Self.minimalArchive()
        archive.archiveVersion = ProfileArchive.currentVersion + 7
        let data = try archive.encodedJSON()
        let expected = ProfileArchiveError.unsupportedVersion(
            found: ProfileArchive.currentVersion + 7,
            supported: ProfileArchive.currentVersion
        )
        #expect(throws: expected) {
            _ = try ProfileArchive.decoded(from: data)
        }
    }

    @Test("a corrupt heatmap blob rolls the whole import back, leaving no profile")
    func corruptHeatBlobLeavesNoPartialProfile() async throws {
        let database = try AppDatabase.makeEmpty()
        let before = try countProfiles(database)
        var archive = Self.minimalArchive()
        archive.segmentHeat = [
            ProfileArchiveSegmentHeat(
                track: ProfileArchiveTrackIdentity(title: "Broken", durationSeconds: 100),
                bucketCounts: Data(count: 399),
                totalPasses: 3,
                updatedAt: ArchiveFixture.createdAt
            ),
        ]
        await #expect(throws: PlaySegmentHeatError.self) {
            _ = try await makeArchiveImporter(database)
                .importArchive(archive, applyingSettingsAndEQPresets: false)
        }
        let after = try countProfiles(database)
        #expect(after == before)
    }

    @Test("a malformed EQ preset rolls the whole import back, leaving no profile")
    func malformedEQPresetLeavesNoPartialProfile() async throws {
        let database = try AppDatabase.makeEmpty()
        let before = try countProfiles(database)
        let archive = Self.minimalArchive(
            eqPresets: [ProfileArchiveEQPreset(name: "Broken", bandGains: [1, 2, 3])]
        )
        await #expect(throws: ProfileArchiveError.invalidEQPreset(name: "Broken", bandCount: 3)) {
            _ = try await makeArchiveImporter(database)
                .importArchive(archive, applyingSettingsAndEQPresets: true)
        }
        let after = try countProfiles(database)
        #expect(after == before)
    }

    @Test("the suggested file name is sanitised and always carries the extension")
    func suggestedFileNameIsSafe() {
        #expect(ProfileArchiveExporter.suggestedFileName(for: "Alex") == "Alex.macampprofile")
        #expect(ProfileArchiveExporter.suggestedFileName(for: "  Alex  ") == "Alex.macampprofile")
        #expect(ProfileArchiveExporter.suggestedFileName(for: "a/b:c") == "a-b-c.macampprofile")
        #expect(ProfileArchiveExporter.suggestedFileName(for: "   ") == "profile.macampprofile")
    }
}
