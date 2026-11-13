import Foundation
import GRDB
@testable import Persistence
import Testing

/// Guards the load-bearing profile-switch invariant: the ``AvailabilityReconciler``
/// stays GLOBAL. A profile switch retargets the folder watcher and reconciles, but a
/// track whose root is excluded from the new profile must remain ``Availability/present``
/// (it is merely invisible to that profile) — the reconciler must NEVER mark an
/// excluded-root track missing just because the active profile does not own its root.
struct ProfileScopedAvailabilityTests {
    @Test func globalReconcilerKeepsExcludedRootTrackPresentAndInvisible() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = TrackRepository(database)
        let profiles = ProfileRepository(database)
        let roots = LibraryRootRepository(database)
        let fileSystem = FakeFileSystem()

        // Guest (profile 1) owns /Music/Guest; the track's file lives there and exists.
        let guestRoot = "/Music/Guest"
        let path = "\(guestRoot)/song.mp3"
        fileSystem.addFile(path)
        let inserted = try tracks.insert(TrackRecord(filePath: path, title: "Song", availability: .present))
        let trackId = try #require(inserted.id)

        // A second profile whose only root is a DIFFERENT folder — it excludes the
        // track's root, so the track is invisible to it after a switch.
        let alex = try profiles.create(ProfileRecord(name: "Alex"))
        let alexId = try #require(alex.id)
        try roots.addRoot(profileId: ProfileRecord.guestID, path: guestRoot)
        try roots.addRoot(profileId: alexId, path: "/Music/Alex")

        // The global reconciler runs (as it does after every switch). The file exists,
        // so availability stays present regardless of which profile is active.
        _ = try AvailabilityReconciler(database, fileSystem: fileSystem).reconcile()

        let after = try #require(try tracks.fetchTrack(id: trackId))
        #expect(after.availability == .present)

        // Scoping is a VISIBILITY concern, not an availability one: Guest sees the
        // track, the excluding profile does not — yet it is still present on disk.
        let guestPage = try await tracks.tracksPage(profileId: ProfileRecord.guestID, after: nil, limit: 100)
        let alexPage = try await tracks.tracksPage(profileId: alexId, after: nil, limit: 100)
        let guestSeesTrack = guestPage.items.contains { $0.id == trackId }
        let alexSeesTrack = alexPage.items.contains { $0.id == trackId }
        #expect(guestSeesTrack)
        #expect(!alexSeesTrack)
    }
}
