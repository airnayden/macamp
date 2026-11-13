import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services

/// A migrated in-memory library plus a recording playlist repository, and the three
/// scripted libraries the hygiene suite reads.
///
/// The playlist seam is `FakePlaylistRepository` rather than the real one for a
/// reason the "pristine library" case needs: it counts every mutating call it is
/// asked to serve, so "the analyzers wrote nothing" is an assertion rather than an
/// argument about what the code appears to do.
///
/// No `libraryRoot` rows are inserted anywhere here, so every track is ownerless and
/// therefore visible to every profile — the visibility-agnostic setup todo 6's
/// learnings describe.
struct LibraryHygieneFixture {
    static let profileId = ProfileRecord.guestID
    static let playlistId: Int64 = 1

    let appDB: AppDatabase
    let playlists: FakePlaylistRepository

    init(membership: [Int64] = []) throws {
        appDB = try AppDatabase.makeEmpty()
        playlists = FakePlaylistRepository(
            playlists: [PlaylistRecord(id: Self.playlistId, name: "Road Trip", profileId: Self.profileId)],
            membership: membership.isEmpty ? [:] : [Self.playlistId: membership]
        )
    }

    /// The service under test. `pageSize` defaults small on purpose: 7 rows a page
    /// over a 20-row library means every assertion runs across three keyset pages,
    /// so a bug that only shows up at a page boundary cannot hide.
    func service(pageSize: Int = 7) -> LibraryHygieneService {
        LibraryHygieneService(
            tracks: TrackRepository(appDB),
            playlists: playlists,
            pageSize: pageSize
        )
    }

    func insert(_ records: [TrackRecord]) throws {
        try appDB.writer.write { db in
            for var record in records {
                try record.insert(db)
            }
        }
    }

    /// A fully-tagged row — no gaps, no cluster, nothing to group — that a caller
    /// bends into whatever the case under test needs.
    ///
    /// The trailing closure keeps the parameter count inside SwiftLint's budget while
    /// leaving every field reachable.
    static func track(
        id: Int64,
        title: String,
        artist: String = "Filler Artist",
        _ customise: (inout TrackRecord) -> Void = { _ in }
    ) -> TrackRecord {
        var record = TrackRecord(
            id: id,
            filePath: "/Music/\(id).flac",
            title: title,
            sortTitle: title.lowercased(),
            artistName: artist,
            duration: 200,
            fileSize: 10_000_000,
            genre: "Rock",
            albumArtist: artist,
            year: 1997
        )
        customise(&record)
        return record
    }
}

// MARK: - The planted library

extension LibraryHygieneFixture {
    /// Twenty present tracks carrying EXACTLY three planted issues:
    ///
    ///   * ids 3 + 4 — one recording, two files (Δduration 1.5 s, Δsize 2.5%).
    ///   * ids 6 + 7 + 8 — "Hip-Hop" twice and "hip hop" once.
    ///   * id 10 — no genre, no year, no album artist, but an artist to derive one.
    ///
    /// Everything else is deliberately a NEAR MISS or a clean row, so a finding count
    /// of three is a real measurement rather than the only thing the fixture allows:
    /// ids 12 + 13 share a title and artist but run 13 s apart, ids 14 + 15 share
    /// title, artist AND runtime but differ 33% in size, and all ten fillers are
    /// fully tagged with a single genre spelling.
    static func plantedLibrary() -> [TrackRecord] {
        duplicatePair() + genreVariants() + [gapTrack()] + nearMisses() + fillers()
    }

    static func duplicatePair() -> [TrackRecord] {
        [
            track(id: 3, title: "Paranoid Android", artist: "Radiohead") { record in
                record.duration = 383
                record.fileSize = 40_000_000
            },
            track(id: 4, title: "Paranoid Android", artist: "Radiohead") { record in
                record.duration = 384.5
                record.fileSize = 39_000_000
            },
        ]
    }

    static func genreVariants() -> [TrackRecord] {
        [
            track(id: 6, title: "Verse One") { $0.genre = "Hip-Hop" },
            track(id: 7, title: "Verse Two") { $0.genre = "Hip-Hop" },
            track(id: 8, title: "Verse Three") { $0.genre = "hip hop" },
        ]
    }

    static func gapTrack() -> TrackRecord {
        track(id: 10, title: "Untagged Demo", artist: "Gap Artist") { record in
            record.genre = nil
            record.year = nil
            record.albumArtist = nil
        }
    }

    /// Same title and artist as each other, but failing one conjunct apiece.
    static func nearMisses() -> [TrackRecord] {
        [
            track(id: 12, title: "Creep", artist: "Radiohead") { $0.duration = 238 },
            track(id: 13, title: "Creep", artist: "Radiohead") { $0.duration = 251 },
            track(id: 14, title: "Karma Police", artist: "Radiohead") { record in
                record.duration = 261
                record.fileSize = 30_000_000
            },
            track(id: 15, title: "Karma Police", artist: "Radiohead") { record in
                record.duration = 261
                record.fileSize = 20_000_000
            },
        ]
    }

    static func fillers() -> [TrackRecord] {
        [1, 2, 5, 9, 11, 16, 17, 18, 19, 20].map { id in
            track(id: id, title: "Filler \(id)")
        }
    }
}

// MARK: - The other two libraries

extension LibraryHygieneFixture {
    /// Twenty fully-tagged rows with distinct titles and one genre spelling.
    static func pristineLibrary() -> [TrackRecord] {
        (1 ... 20).map { id in track(id: Int64(id), title: "Clean \(id)") }
    }

    /// The same three issues as ``plantedLibrary()``, except the second half of each
    /// one is unreachable — so every finding depends on a row the analyzers must
    /// refuse to look at.
    static func unavailableLibrary() -> [TrackRecord] {
        [
            track(id: 1, title: "Paranoid Android", artist: "Radiohead") { record in
                record.duration = 383
                record.fileSize = 40_000_000
            },
            track(id: 2, title: "Paranoid Android", artist: "Radiohead") { record in
                record.duration = 384.5
                record.fileSize = 39_000_000
                record.availability = .missing
            },
            track(id: 3, title: "Verse One") { $0.genre = "Hip-Hop" },
            track(id: 4, title: "Verse Two") { record in
                record.genre = "hip hop"
                record.availability = .externalOffline
            },
            track(id: 5, title: "Untagged Demo", artist: "Gap Artist") { record in
                record.genre = nil
                record.year = nil
                record.albumArtist = nil
                record.availability = .missing
            },
        ]
    }

    /// `count` gap rows, for proving the output ceiling clamps an over-large `limit`.
    static func gapLibrary(count: Int) -> [TrackRecord] {
        (1 ... count).map { id in
            track(id: Int64(id), title: "Gap \(id)", artist: "Gap Artist") { record in
                record.genre = nil
                record.year = nil
                record.albumArtist = nil
            }
        }
    }
}
