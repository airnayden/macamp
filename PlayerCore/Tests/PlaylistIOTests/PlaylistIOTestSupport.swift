import Foundation
import GRDB
import Persistence

enum FixtureError: Error {
    case notInserted
}

enum PlaylistIOFixtures {
    /// Inserts a track with display title/artist (for playlist export formatting).
    @discardableResult
    static func insertNamedTrack(
        _ database: Database,
        path: String,
        title: String?,
        artist: String?,
        duration: Double? = nil
    ) throws -> Int64 {
        var track = TrackRecord(
            filePath: path,
            title: title,
            sortTitle: title ?? path,
            artistName: artist,
            duration: duration
        )
        try track.insert(database)
        return try requireID(track.id)
    }

    static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }

    static func fixtureContents(_ name: String) throws -> String {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
    }

    private static func requireID(_ id: Int64?) throws -> Int64 {
        guard let id else {
            throw FixtureError.notInserted
        }
        return id
    }
}
