import Foundation
import GRDB
@testable import Persistence
import Testing

/// Removing a library folder removes its tracks, and the orphan sweep clears
/// missing tracks that no folder covers. Without this, a removed folder's tracks
/// fell outside every root and showed up in every profile's All Tracks as
/// "loose" files with a warning badge.
struct LibraryRootPruningTests {
    private let guest = ProfileRecord.guestID

    private func makeTrack(_ path: String, _ availability: Availability = .present) -> TrackRecord {
        TrackRecord(filePath: path, title: "Song", availability: availability)
    }

    private func paths(_ database: AppDatabase) throws -> Set<String> {
        try database.writer.read { db in
            try Set(String.fetchAll(db, sql: "SELECT filePath FROM track"))
        }
    }

    @Test("Removing a folder removes the tracks inside it, and only those")
    func removedFolderTakesItsTracks() throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = TrackRepository(database)
        try LibraryRootRepository(database).addRoot(profileId: guest, path: "/Music/Kept")
        try tracks.insert(makeTrack("/Music/Removed/a.mp3"))
        try tracks.insert(makeTrack("/Music/Removed/sub/b.flac", .missing))
        try tracks.insert(makeTrack("/Music/Kept/c.mp3"))
        try tracks.insert(makeTrack("/Music/Removed Videos/d.mp3"))

        let removed = try AvailabilityReconciler(database).removeTracks(underRemovedRoot: "/Music/Removed/")

        #expect(removed == 2)
        #expect(try paths(database) == ["/Music/Kept/c.mp3", "/Music/Removed Videos/d.mp3"])
    }

    @Test("A folder another profile still has keeps its tracks")
    func folderSharedWithAnotherProfileIsKept() throws {
        let database = try AppDatabase.makeEmpty()
        let alex = try #require(ProfileRepository(database).create(ProfileRecord(name: "Alex")).id)
        try LibraryRootRepository(database).addRoot(profileId: alex, path: "/Music/Shared")
        try TrackRepository(database).insert(makeTrack("/Music/Shared/a.mp3"))

        // Guest removed its copy of /Music/Shared; Alex's row is still there.
        let removed = try AvailabilityReconciler(database).removeTracks(underRemovedRoot: "/Music/Shared")

        #expect(removed == 0)
        #expect(try paths(database) == ["/Music/Shared/a.mp3"])
    }

    @Test("Removing a subfolder of a configured folder keeps its tracks")
    func enclosingFolderStillCoversTracks() throws {
        let database = try AppDatabase.makeEmpty()
        try LibraryRootRepository(database).addRoot(profileId: guest, path: "/Music")
        try TrackRepository(database).insert(makeTrack("/Music/Rock/a.mp3"))

        let removed = try AvailabilityReconciler(database).removeTracks(underRemovedRoot: "/Music/Rock")

        #expect(removed == 0)
    }

    @Test("The sweep removes missing tracks outside every folder, and nothing else")
    func sweepRemovesOnlyOrphanedMissingTracks() throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = TrackRepository(database)
        try LibraryRootRepository(database).addRoot(profileId: guest, path: "/Music/Library")
        try tracks.insert(makeTrack("/Old/Folder/gone.mp3", .missing)) // leftover of a removed folder
        try tracks.insert(makeTrack("/Old/Folder/drive.mp3", .externalOffline)) // unplugged drive
        try tracks.insert(makeTrack("/Downloads/loose.mp3")) // loose import, still on disk
        try tracks.insert(makeTrack("/Music/Library/moved.mp3", .missing)) // inside a folder: keep the badge

        let removed = try AvailabilityReconciler(database).pruneOrphanedMissingTracks()

        #expect(removed == 1)
        #expect(try paths(database) == [
            "/Old/Folder/drive.mp3", "/Downloads/loose.mp3", "/Music/Library/moved.mp3",
        ])
    }

    @Test("With no folders configured the sweep never deletes anything")
    func sweepIsInertWithoutAnyFolder() throws {
        let database = try AppDatabase.makeEmpty()
        try TrackRepository(database).insert(makeTrack("/Anywhere/a.mp3", .missing))

        let removed = try AvailabilityReconciler(database).pruneOrphanedMissingTracks()

        #expect(removed == 0)
        #expect(try paths(database).count == 1)
    }

    @Test("Folder paths with LIKE wildcards only match themselves")
    func wildcardCharactersAreEscaped() throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = TrackRepository(database)
        try LibraryRootRepository(database).addRoot(profileId: guest, path: "/Music/100%_Hits")
        try tracks.insert(makeTrack("/Music/100%_Hits/a.mp3", .missing))
        try tracks.insert(makeTrack("/Music/100XYHits/b.mp3", .missing))

        let removed = try AvailabilityReconciler(database).pruneOrphanedMissingTracks()

        #expect(removed == 1)
        #expect(try paths(database) == ["/Music/100%_Hits/a.mp3"])
    }
}
