// AutoMixListViewModelTests — the two promises the iOS Auto Mixes section rests on.
//
// Profile scoping is asserted against a REAL ``GeneratedPlaylistService`` over a
// migrated in-memory database, because "profile A never sees profile B's mixes" is
// a property of the join that lists them; a canned fake would only prove the view
// model forwarded an id. Refresh-on-appear is asserted against the scripted fake
// instead, because it is a claim about CALLS, not about rows.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

@MainActor
struct AutoMixListViewModelTests {
    // MARK: - The listing is scoped to the view model's profile

    @Test func mixesAreScopedToTheActiveProfile() async throws {
        let fixture = try AutoMixFixture()
        let otherId = try fixture.makeProfile(named: "Other")

        let guest = fixture.makeViewModel(profileId: ProfileRecord.guestID)
        let other = fixture.makeViewModel(profileId: otherId)
        await guest.load()
        await other.load()

        // Both profiles materialised the same two kinds…
        #expect(guest.mixes.map(\.generatorKind) == ["daypartMix", "rediscovery"])
        #expect(other.mixes.map(\.generatorKind) == ["daypartMix", "rediscovery"])
        // …into DIFFERENT playlists, and neither lists the other's.
        #expect(guest.playlistIds.isDisjoint(with: other.playlistIds))
        let guestOwners = try fixture.owners(of: guest.playlistIds)
        let otherOwners = try fixture.owners(of: other.playlistIds)
        #expect(guestOwners == [ProfileRecord.guestID])
        #expect(otherOwners == [otherId])
    }

    @Test func aSecondProfileSeesNothingBeforeItRefreshes() async throws {
        let fixture = try AutoMixFixture()
        let otherId = try fixture.makeProfile(named: "Other")

        let guest = fixture.makeViewModel(profileId: ProfileRecord.guestID)
        await guest.load()

        let other = fixture.makeViewModel(profileId: otherId)
        let listed = try await fixture.service.generatedPlaylists(profileId: otherId)
        #expect(listed.isEmpty)
        #expect(other.mixes.isEmpty)
        #expect(!guest.mixes.isEmpty)
    }

    // MARK: - Refresh runs once per appearance, never per render

    @Test func loadRefreshesExactlyOncePerAppearance() async {
        let service = FakeGeneratedPlaylistService()
        service.summaries = [Self.summary(playlistId: 7)]
        let model = AutoMixListViewModel(service: service, activeProfileId: 42)

        await model.load()

        #expect(service.refreshedProfileIds == [42])
        #expect(service.listedProfileIds == [42])
        // Rendering reads the published state as often as it likes; none of that
        // is an appearance, so none of it refreshes.
        for _ in 0 ..< 5 {
            _ = model.mixes
            _ = model.playlistIds
            _ = model.isLoading
        }
        #expect(service.refreshedProfileIds == [42])
    }

    @Test func aSecondAppearanceRefreshesAgain() async {
        let service = FakeGeneratedPlaylistService()
        let model = AutoMixListViewModel(service: service, activeProfileId: 1)

        await model.load()
        await model.load()

        #expect(service.refreshedProfileIds == [1, 1])
    }

    /// A render that lands mid-load must not queue a second refresh. The gate is
    /// what makes the overlap real: with a fake that returns without suspending,
    /// the "concurrent" calls would simply run one after the other.
    @Test func overlappingLoadsCollapseToOneRefresh() async {
        let service = GatedGeneratedPlaylistService()
        let model = AutoMixListViewModel(service: service, activeProfileId: 1)

        async let first: Bool = model.load()
        await service.waitUntilEntered()
        let second = await model.load()
        service.open()
        _ = await first

        #expect(second == false)
        #expect(service.refreshCount == 1)
    }

    // MARK: - What the caller is told, and what a failure costs

    @Test func loadReportsWhetherARefreshMaterialisedAnything() async {
        let service = FakeGeneratedPlaylistService()
        let model = AutoMixListViewModel(service: service, activeProfileId: 1)

        #expect(await model.load() == false)

        service.refreshes = [
            GeneratedPlaylistRefresh(
                kind: .daypartMix,
                playlistId: 3,
                trackIds: [1, 2],
                created: true,
                refreshedAt: 0
            ),
        ]
        #expect(await model.load() == true)
    }

    @Test func aFailedLoadKeepsTheListingItHad() async {
        let service = FakeGeneratedPlaylistService()
        service.summaries = [Self.summary(playlistId: 7)]
        let model = AutoMixListViewModel(service: service, activeProfileId: 1)
        await model.load()
        #expect(model.playlistIds == [7])

        service.error = FakeMixGeneratorError.forcedFailure
        await model.load()

        #expect(model.playlistIds == [7])
        #expect(model.isLoading == false)
    }

    private static func summary(playlistId: Int64) -> GeneratedPlaylistSummary {
        GeneratedPlaylistSummary(
            playlistId: playlistId,
            name: "Daily Mix",
            generatorKind: GeneratedPlaylistKind.daypartMix.rawValue,
            lastRefreshedAt: nil
        )
    }
}

// MARK: - A refresh that can be held open

/// A ``GeneratedPlaylistProviding`` whose refresh parks until it is opened, so a
/// second call can be made while the first is provably still in flight.
@MainActor
private final class GatedGeneratedPlaylistService: GeneratedPlaylistProviding {
    private(set) var refreshCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    @discardableResult
    func refreshIfStale(profileId _: Int64) async throws -> [GeneratedPlaylistRefresh] {
        refreshCount += 1
        guard !isOpen else { return [] }
        await withCheckedContinuation { waiters.append($0) }
        return []
    }

    func generatedPlaylists(profileId _: Int64) async throws -> [GeneratedPlaylistSummary] {
        []
    }

    /// Yields until a refresh has entered and parked. Bounded, so a wiring
    /// mistake fails the assertion instead of hanging the suite.
    func waitUntilEntered() async {
        for _ in 0 ..< 1000 where refreshCount == 0 {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters = []
        for waiter in parked {
            waiter.resume()
        }
    }
}

// MARK: - Fixture

/// A migrated in-memory database, a scripted generator and one real service —
/// the smallest graph that materialises real per-profile playlist rows.
@MainActor
private final class AutoMixFixture {
    let appDB: AppDatabase
    let service: GeneratedPlaylistService

    init() throws {
        appDB = try AppDatabase.makeEmpty()
        let generator = FakeMixGeneratorService()
        generator.seed(.daypart, draft: Self.draft([1, 2], kind: .daypart))
        generator.seed(.rediscovery, draft: Self.draft([2, 3], kind: .rediscovery))
        service = GeneratedPlaylistService(
            appDB.writer,
            playlists: PlaylistRepository(appDB),
            generator: generator,
            aiSettings: FakeAISettings()
        )
        try appDB.writer.write { db in
            for trackId in Int64(1) ... 3 {
                var record = TrackRecord(id: trackId, filePath: "/Music/\(trackId).flac", duration: 200)
                try record.insert(db)
            }
        }
    }

    func makeViewModel(profileId: Int64) -> AutoMixListViewModel {
        AutoMixListViewModel(service: service, activeProfileId: profileId)
    }

    func makeProfile(named name: String) throws -> Int64 {
        try appDB.writer.write { db in
            var record = ProfileRecord(name: name)
            try record.insert(db)
            return record.id ?? 0
        }
    }

    /// The distinct profiles owning `playlistIds` — one element means one owner.
    func owners(of playlistIds: Set<Int64>) throws -> [Int64] {
        let owned = try appDB.writer.read { db in
            try PlaylistRecord
                .filter(keys: playlistIds)
                .fetchAll(db)
                .compactMap(\.profileId)
        }
        return owned.reduce(into: [Int64]()) { unique, profileId in
            if !unique.contains(profileId) { unique.append(profileId) }
        }
    }

    private static func draft(_ ids: [Int64], kind: MixSourceKind) -> PlaylistDraft {
        PlaylistDraft(
            entries: ids.map { MixDraftEntry(trackId: $0, provenance: .rulesResult, score: 1) },
            nameHint: MixNameHint(sourceKind: kind, trackCount: ids.count, daypart: nil)
        )
    }
}
