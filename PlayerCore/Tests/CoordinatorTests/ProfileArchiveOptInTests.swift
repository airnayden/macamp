// ProfileArchiveOptInTests — the opt-in globals, and the identity matcher itself.
//
// Statistics restore unconditionally; preferences and custom EQ presets do not, and
// even when they do they must never overwrite what the user already has. The matcher
// tests below pin the rule that decides which archived row is allowed to attach to
// which local track — the single place where getting it wrong mis-attributes someone
// else's listening history.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

@Suite("Profile archive opt-in globals")
struct ProfileArchiveOptInTests {
    static let brightGains: [Double] = [6, 5, 4, 2, 0, 0, 2, 4, 5, 6]
    static let warmGains: [Double] = [4, 3, 2, 1, 0, 0, -1, -2, -3, -4]

    static func archiveWithGlobals() -> ProfileArchive {
        ProfileArchive(
            profile: ProfileArchiveProfile(
                name: "Sam",
                avatarId: ProfileRecord.defaultAvatarID,
                createdAt: ArchiveFixture.createdAt
            ),
            settings: ArchiveFixture.settings,
            eqPresets: [
                ProfileArchiveEQPreset(name: "Bright", bandGains: brightGains, preamp: -3),
                ProfileArchiveEQPreset(name: "Warm", bandGains: warmGains),
            ]
        )
    }

    @Test("opting out imports the statistics but no settings and no presets")
    func optingOutLeavesGlobalsAlone() async throws {
        let database = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(database)
        try store.save(EQPreset(name: "Bright", bandGains: [Float](repeating: 1, count: 10)))

        let summary = try await makeArchiveImporter(database)
            .importArchive(Self.archiveWithGlobals(), applyingSettingsAndEQPresets: false)

        #expect(summary.settings == nil)
        #expect(summary.importedEQPresets == 0)
        #expect(summary.renamedEQPresets.isEmpty)
        let presets = try store.loadAll()
        #expect(presets.count == 1)
        #expect(presets.first?.bandGains == [Float](repeating: 1, count: 10))
        // The profile itself still arrived.
        #expect(fetchProfileExists(database, id: summary.profileId))
    }

    @Test("opting in hands the settings snapshot back for the shell to apply")
    func optingInReturnsTheSettingsSnapshot() async throws {
        let database = try AppDatabase.makeEmpty()
        let summary = try await makeArchiveImporter(database)
            .importArchive(Self.archiveWithGlobals(), applyingSettingsAndEQPresets: true)
        #expect(summary.settings == ArchiveFixture.settings)
    }

    @Test("a colliding preset name is renamed, never overwritten")
    func collidingPresetIsRenamed() async throws {
        let database = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(database)
        let original = EQPreset(name: "Bright", bandGains: [Float](repeating: 1, count: 10), preamp: 0)
        try store.save(original)

        let summary = try await makeArchiveImporter(database)
            .importArchive(Self.archiveWithGlobals(), applyingSettingsAndEQPresets: true)

        #expect(summary.importedEQPresets == 2)
        #expect(summary.renamedEQPresets == ["Bright (imported)"])
        let presets = try store.loadAll()
        #expect(presets.map(\.name).sorted() == ["Bright", "Bright (imported)", "Warm"])
        let kept = try #require(presets.first { $0.name == "Bright" })
        #expect(kept == original)
        let imported = try #require(presets.first { $0.name == "Bright (imported)" })
        #expect(imported.bandGains == Self.brightGains.map(Float.init))
        #expect(imported.preamp == -3)
    }

    @Test("importing the same archive twice keeps disambiguating preset names")
    func repeatedPresetImportsKeepDisambiguating() async throws {
        let database = try AppDatabase.makeEmpty()
        let importer = makeArchiveImporter(database)
        _ = try await importer.importArchive(Self.archiveWithGlobals(), applyingSettingsAndEQPresets: true)
        let second = try await importer.importArchive(Self.archiveWithGlobals(), applyingSettingsAndEQPresets: true)

        #expect(second.renamedEQPresets == ["Bright (imported)", "Warm (imported)"])
        let names = try GRDBEQPresetStore(database).loadAll().map(\.name).sorted()
        #expect(names == ["Bright", "Bright (imported)", "Warm", "Warm (imported)"])
    }

    @Test("the disambiguating suffix is caller-supplied so the shell can localize it")
    func presetSuffixIsInjectable() async throws {
        let database = try AppDatabase.makeEmpty()
        try GRDBEQPresetStore(database).save(EQPreset(name: "Bright", bandGains: [Float](repeating: 0, count: 10)))
        let summary = try await makeArchiveImporter(database).importArchive(
            Self.archiveWithGlobals(),
            applyingSettingsAndEQPresets: true,
            importedPresetSuffix: "(importé)"
        )
        #expect(summary.renamedEQPresets == ["Bright (importé)"])
    }
}

// MARK: - Matcher

@Suite("Profile archive track matcher")
struct ProfileArchiveTrackMatcherTests {
    static let songA = ProfileArchiveTrackIdentity(
        artistName: "Artist A", title: "Song A", albumTitle: "Album A", durationSeconds: 250
    )

    static func matcher(offering locals: [ProfileArchiveLocalTrack]) -> ProfileArchiveTrackMatcher {
        var matcher = ProfileArchiveTrackMatcher(identities: [songA])
        for local in locals {
            matcher.offer(local)
        }
        return matcher
    }

    static func local(_ trackId: Int64, duration: Double? = 250, title: String = "Song A") -> ProfileArchiveLocalTrack {
        ProfileArchiveLocalTrack(
            trackId: trackId,
            title: title,
            artistName: "Artist A",
            albumTitle: "Album A",
            durationSeconds: duration
        )
    }

    @Test("a single exact candidate matches")
    func singleExactCandidateMatches() {
        #expect(Self.matcher(offering: [Self.local(7)]).localTrackId(for: Self.songA) == 7)
    }

    @Test("matching is case-insensitive without being locale-sensitive")
    func matchingIsCaseInsensitive() {
        let shouted = ProfileArchiveLocalTrack(
            trackId: 9, title: "SONG A", artistName: "ARTIST A", albumTitle: "ALBUM A", durationSeconds: 250
        )
        #expect(Self.matcher(offering: [shouted]).localTrackId(for: Self.songA) == 9)
    }

    @Test("durations may differ by up to one second")
    func durationToleranceIsOneSecond() {
        #expect(Self.matcher(offering: [Self.local(1, duration: 251)]).localTrackId(for: Self.songA) == 1)
        #expect(Self.matcher(offering: [Self.local(1, duration: 249)]).localTrackId(for: Self.songA) == 1)
        #expect(Self.matcher(offering: [Self.local(1, duration: 251.5)]).localTrackId(for: Self.songA) == nil)
    }

    @Test("an unknown duration on either side never rejects a candidate")
    func unknownDurationNeverRejects() {
        #expect(Self.matcher(offering: [Self.local(3, duration: nil)]).localTrackId(for: Self.songA) == 3)
        var matcher = ProfileArchiveTrackMatcher(identities: [
            ProfileArchiveTrackIdentity(artistName: "Artist A", title: "Song A", albumTitle: "Album A"),
        ])
        matcher.offer(Self.local(4, duration: 9999))
        let unknownDuration = ProfileArchiveTrackIdentity(
            artistName: "Artist A", title: "Song A", albumTitle: "Album A"
        )
        #expect(matcher.localTrackId(for: unknownDuration) == 4)
    }

    @Test("an ambiguous multi-match resolves to unmatched, never to a guess")
    func ambiguousMultiMatchIsUnmatched() {
        let both = Self.matcher(offering: [Self.local(1), Self.local(2)])
        #expect(both.localTrackId(for: Self.songA) == nil)
    }

    @Test("duration disambiguates two candidates that share a name")
    func durationDisambiguates() {
        let matcher = Self.matcher(offering: [Self.local(1, duration: 250), Self.local(2, duration: 400)])
        #expect(matcher.localTrackId(for: Self.songA) == 1)
    }

    @Test("too many identical candidates is treated as ambiguous, not scanned forever")
    func overflowingCandidatesIsAmbiguous() {
        let locals = (1 ... 20).map { Self.local(Int64($0), duration: Double(1000 + $0)) }
        #expect(Self.matcher(offering: locals).localTrackId(for: Self.songA) == nil)
    }

    @Test("a track the archive never mentions is ignored outright")
    func unseededIdentityIsIgnored() {
        let matcher = Self.matcher(offering: [Self.local(1, title: "Some Other Song")])
        #expect(matcher.localTrackId(for: Self.songA) == nil)
        let stranger = ProfileArchiveTrackIdentity(
            artistName: "Artist A", title: "Some Other Song", albumTitle: "Album A", durationSeconds: 250
        )
        #expect(matcher.localTrackId(for: stranger) == nil)
    }

    @Test("an empty matcher reports itself empty so the library scan can be skipped")
    func emptyMatcherIsEmpty() {
        #expect(ProfileArchiveTrackMatcher(identities: []).isEmpty)
        #expect(!ProfileArchiveTrackMatcher(identities: [Self.songA]).isEmpty)
    }
}

// MARK: - Shared helper

func fetchProfileExists(_ database: AppDatabase, id: Int64) -> Bool {
    ((try? fetchProfile(database, id: id)) ?? nil) != nil
}
