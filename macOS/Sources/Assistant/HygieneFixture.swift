// HygieneFixture — the library shape the library-health UI test needs.
//
// The base UI-test fixture (`AppEnvironment+UITesting`) seeds two tracks with no
// genre, no year, no album artist and — crucially — NO FILE SIZE. That already
// produces metadata-gap findings, but it can never produce the other two:
//
//   * `LibraryHygieneService` calls two rows the same recording only when title,
//     artist, duration AND file size all agree. A row with a `nil` `fileSize`
//     therefore never groups, by design ("a conjunct that cannot be evaluated cannot
//     be satisfied"), so the base fixture yields zero duplicates however many copies
//     it holds.
//   * A genre cluster needs two spellings of one genre, and the base fixture has no
//     genre at all.
//
// This fixture supplies exactly those two shapes, plus the playlist that turns the
// duplicate into an actionable `.organize` proposal — a duplicate no playlist lists
// twice is deliberately not actionable, which would make the end-to-end Apply path
// unreachable.
//
// Applied ONLY when the launch environment asks for it, so every pre-existing suite
// sees the byte-identical fixture it saw before. The switch itself now lives in
// ``UITestFixtureOptions`` alongside every other one; this fixture used to read its
// own key from inside `seedIfRequested` purely to keep `makeUITestDatabase` under the
// parameter-count ceiling, which the bundled options type solves properly.
import Foundation
import GRDB
import Persistence

#if DEBUG
    enum HygieneFixture {
        /// Launch-environment switch. Absent ⇒ this file changes nothing.
        static let environmentKey = "UITEST_SEED_HYGIENE"
        /// The playlist that lists the duplicated recording twice.
        static let playlistName = "Hygiene Mix"
        /// The second library row for the first fixture recording. Its title differs
        /// only in case, which ``SortKey`` folds away.
        static let duplicateTrackTitle = "AURORA ANTHEM"
        /// The majority spelling — what a genre cluster would settle on.
        static let canonicalGenre = "Hip Hop"
        /// The minority spelling, folding onto the same key as ``canonicalGenre``.
        static let variantGenre = "Hip-Hop"
        /// Byte size written onto the base rows. Any non-`nil` value works; a
        /// plausible one keeps the Info panel readable.
        static let baseFileSize: Int64 = 4_000_000
        /// The duplicate's size, 1.2% off ``baseFileSize`` — inside the analyzer's
        /// 5% tolerance, so the two rows group.
        static let duplicateFileSize: Int64 = 4_050_000

        static func seed(into database: AppDatabase) throws {
            try database.writer.write { db in
                let present = try TrackRecord.order(TrackRecord.Columns.id).fetchAll(db)
                try tagBaseTracks(present, in: db)
                guard let duplicateId = try insertDuplicateTrack(of: present.first, into: db) else { return }
                try insertPlaylist(membership: present.compactMap(\.id) + [duplicateId], into: db)
            }
        }

        /// Gives the base rows a file size (so the duplicate rule can be evaluated at
        /// all) and the canonical genre spelling. Year and album artist stay absent,
        /// so the gap analyzer still has something to report.
        private static func tagBaseTracks(_ tracks: [TrackRecord], in db: Database) throws {
            for var track in tracks {
                track.fileSize = baseFileSize
                track.genre = canonicalGenre
                try track.update(db)
            }
        }

        private static func insertDuplicateTrack(
            of original: TrackRecord?,
            into db: Database
        ) throws -> Int64? {
            guard let original else { return nil }
            var record = TrackRecord(
                filePath: "\(original.filePath).hygiene-duplicate.mp3",
                title: duplicateTrackTitle,
                sortTitle: "zzz \(duplicateTrackTitle.lowercased())",
                artistName: original.artistName,
                duration: original.duration,
                fileSize: duplicateFileSize,
                availability: .present,
                genre: variantGenre
            )
            try record.insert(db)
            return record.id
        }

        private static func insertPlaylist(membership: [Int64], into db: Database) throws {
            guard !membership.isEmpty else { return }
            var playlist = PlaylistRecord(name: playlistName, profileId: ProfileRecord.guestID)
            try playlist.insert(db)
            guard let playlistId = playlist.id else { return }
            for (position, trackId) in membership.enumerated() {
                var entry = PlaylistTrackRecord(playlistId: playlistId, trackId: trackId, position: position)
                try entry.insert(db)
            }
        }
    }
#endif
