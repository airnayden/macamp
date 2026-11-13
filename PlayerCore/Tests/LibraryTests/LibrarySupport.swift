import Foundation
import GRDB
import Persistence

/// A thread-safe collector of traced SQL statements, used to prove N+1 avoidance.
///
/// Installed on every connection via `Configuration.prepareDatabase`, so it also
/// captures statements issued inside a repository's encapsulated `read`/`write`
/// closures — which a per-`read` trace could not reach.
final class SQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func record(_ sql: String) {
        lock.lock()
        collected.append(sql)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        collected = []
        lock.unlock()
    }

    var statements: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var selectCount: Int {
        statements.count { $0.uppercased().hasPrefix("SELECT") }
    }
}

enum LibraryFixtures {
    /// An in-memory migrated database whose every SQL statement is traced.
    static func makeTracedDatabase() throws -> (AppDatabase, SQLTrace) {
        let trace = SQLTrace()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace(options: .statement) { event in
                if case let .statement(statement) = event {
                    trace.record(statement.sql)
                }
            }
        }
        let appDB = try AppDatabase(DatabaseQueue(configuration: config))
        return (appDB, trace)
    }

    /// Inserts `count` tracks with zero-padded, strictly increasing sort titles and
    /// `dateAdded`, so keyset order and "recently added" order are deterministic.
    static func seedTracks(_ appDB: AppDatabase, count: Int) throws {
        try appDB.writer.write { db in
            for index in 0 ..< count {
                let label = String(format: "Track %05d", index)
                var track = TrackRecord(
                    filePath: "/music/seq/\(index).flac",
                    title: label,
                    sortTitle: label,
                    artistName: "Artist \(index % 7)",
                    albumTitle: "Album \(index % 11)",
                    dateAdded: Double(index)
                )
                try track.insert(db)
            }
        }
    }

    /// Inserts a fixed genre corpus — `jazz` Jazz, `rock` Rock, `pop` Pop and
    /// `untagged` genre-less tracks — with stable ids/titles so genre-filter
    /// assertions are deterministic.
    static func seedGenreLibrary(
        _ appDB: AppDatabase,
        jazz: Int = 3,
        rock: Int = 2,
        pop: Int = 2,
        untagged: Int = 2
    ) throws {
        try appDB.writer.write { db in
            var index = 0
            func insert(_ count: Int, genre: String?) throws {
                for _ in 0 ..< count {
                    let label = String(format: "Track %05d", index)
                    var track = TrackRecord(
                        filePath: "/music/genre/\(index).flac",
                        title: label,
                        sortTitle: label,
                        genre: genre
                    )
                    try track.insert(db)
                    index += 1
                }
            }
            try insert(jazz, genre: "Jazz")
            try insert(rock, genre: "Rock")
            try insert(pop, genre: "Pop")
            try insert(untagged, genre: nil)
        }
    }

    /// Inserts `albumCount` albums, each with `tracksPerAlbum` tracks.
    static func seedAlbums(_ appDB: AppDatabase, albumCount: Int, tracksPerAlbum: Int) throws {
        try appDB.writer.write { db in
            for albumIndex in 0 ..< albumCount {
                var album = AlbumRecord(
                    title: "Album \(albumIndex)",
                    sortTitle: String(format: "Album %05d", albumIndex)
                )
                try album.insert(db)
                for trackIndex in 0 ..< tracksPerAlbum {
                    var track = TrackRecord(
                        filePath: "/music/\(albumIndex)/\(trackIndex).flac",
                        title: "Track \(trackIndex)",
                        albumId: album.id
                    )
                    try track.insert(db)
                }
            }
        }
    }

    /// Inserts `artistCount` artists, each crediting `albumsPerArtist` albums.
    static func seedArtists(_ appDB: AppDatabase, artistCount: Int, albumsPerArtist: Int) throws {
        try appDB.writer.write { db in
            for artistIndex in 0 ..< artistCount {
                var artist = ArtistRecord(
                    name: "Artist \(artistIndex)",
                    sortName: String(format: "Artist %05d", artistIndex)
                )
                try artist.insert(db)
                for albumIndex in 0 ..< albumsPerArtist {
                    var album = AlbumRecord(
                        title: "Alb \(albumIndex)",
                        sortTitle: "Alb \(albumIndex)",
                        artistId: artist.id
                    )
                    try album.insert(db)
                }
            }
        }
    }

    struct KnownTrack {
        let title: String
        let artistName: String
        let albumTitle: String
    }

    /// A small, hand-picked corpus exercising prefix, multi-term, ranked, and
    /// accent-folded full-text matching.
    static let searchCorpus: [KnownTrack] = [
        KnownTrack(title: "Bohemian Rhapsody", artistName: "Queen", albumTitle: "A Night at the Opera"),
        KnownTrack(title: "Bohemian Like You", artistName: "The Dandy Warhols", albumTitle: "Thirteen Tales"),
        KnownTrack(title: "Killer Queen", artistName: "Queen", albumTitle: "Sheer Heart Attack"),
        KnownTrack(title: "Café del Mar", artistName: "Energy 52", albumTitle: "Classics"),
        KnownTrack(title: "La Bohème", artistName: "Charles Aznavour", albumTitle: "Greatest Hits"),
        KnownTrack(title: "Naïve", artistName: "The Kooks", albumTitle: "Inside In/Inside Out"),
    ]

    static func seedSearchCorpus(_ appDB: AppDatabase) throws {
        try appDB.writer.write { db in
            for (index, known) in searchCorpus.enumerated() {
                var track = TrackRecord(
                    filePath: "/music/search/\(index).flac",
                    title: known.title,
                    sortTitle: known.title,
                    artistName: known.artistName,
                    albumTitle: known.albumTitle
                )
                try track.insert(db)
            }
        }
    }
}
