import Foundation
import GRDB

// Removing a library folder used to only mark its tracks missing, so they stayed
// in All Tracks with a warning badge until each was deleted by hand. Removing a
// folder now removes its tracks from the library, and a sweep clears the tracks
// such removals left behind before.
//
// Tracks are library-wide while folders belong to a profile, so a track is only
// ever removed when NO profile still has a folder that contains it. Deleting a
// track row cascades to its play history and playlist entries, exactly like
// "Delete from Library" in the track list.

public extension AvailabilityReconciling {
    /// Default for conformers that predate pruning: fall back to marking the
    /// root's tracks missing, the previous behaviour.
    @discardableResult
    func removeTracks(underRemovedRoot rootPath: String) throws -> Int {
        try markMissing(rootPath: rootPath)
    }

    /// Default for conformers that predate pruning: nothing to sweep.
    @discardableResult
    func pruneOrphanedMissingTracks() throws -> Int {
        0
    }
}

public extension AvailabilityReconciler {
    /// Deletes the tracks under `rootPath`, a library folder the user just
    /// removed, except those still covered by a configured folder in any profile
    /// (another profile's copy of the folder, or an enclosing folder).
    ///
    /// Call it after the folder's own `libraryRoot` row is gone.
    /// - Returns: The number of tracks removed from the library.
    @discardableResult
    func removeTracks(underRemovedRoot rootPath: String) throws -> Int {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                DELETE FROM \(TrackRecord.databaseTableName)
                WHERE filePath LIKE ? ESCAPE '\\'
                AND \(Self.notUnderAnyRootSQL)
                """,
                arguments: [TrackRepository.likePrefixPattern(forRoot: rootPath)]
            )
            return db.changesCount
        }
    }

    /// Deletes tracks that are missing from disk and sit outside every
    /// configured library folder in every profile: the leftovers of folders
    /// removed before ``removeTracks(underRemovedRoot:)`` existed, or of loose
    /// files that were later deleted.
    ///
    /// Tracks on an unplugged drive are `externalOffline`, not `missing`, so they
    /// are never swept. With no folders configured at all the sweep does nothing,
    /// so a half-initialised database can never lose its library.
    /// - Returns: The number of tracks removed from the library.
    @discardableResult
    func pruneOrphanedMissingTracks() throws -> Int {
        try dbWriter.write { db in
            let rootCount = try LibraryRootRecord.fetchCount(db)
            guard rootCount > 0 else { return 0 }
            try db.execute(
                sql: """
                DELETE FROM \(TrackRecord.databaseTableName)
                WHERE availability = ?
                AND \(Self.notUnderAnyRootSQL)
                """,
                arguments: [Availability.missing]
            )
            return db.changesCount
        }
    }

    /// `track.filePath` is not inside any `libraryRoot.path`. The root is turned
    /// into a LIKE prefix the same way ``TrackRepository/likePrefixPattern(forRoot:)``
    /// does it in Swift: trailing slashes dropped, `\`, `%` and `_` escaped, then
    /// `/%` appended, so `/Music` never matches `/Music Videos`.
    private static let notUnderAnyRootSQL = #"""
    NOT EXISTS (
        SELECT 1 FROM libraryRoot AS root
        WHERE track.filePath LIKE
            replace(replace(replace(rtrim(root.path, '/'), '\', '\\'), '%', '\%'), '_', '\_') || '/%'
            ESCAPE '\'
    )
    """#
}
