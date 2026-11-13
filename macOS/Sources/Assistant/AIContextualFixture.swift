// AIContextualFixture — the extra library shape the contextual-action UI tests need.
//
// The base UI-test fixture (`AppEnvironment+UITesting`) seeds two tracks with NO
// `artistId`, NO genre and NO playlist, which is exactly right for the browsing
// suites and exactly wrong here:
//
//   * `SimilarityService.metadataNeighbors` narrows its cold-start artist pool by the
//     `artistId` FOREIGN KEY, not by the denormalized `artistName` string, so with no
//     artist row every seed has zero neighbours and "More Like This" correctly
//     produces nothing — a happy-path assertion would fail for a reason that has
//     nothing to do with the menu under test.
//   * "Organize…" needs a playlist to organize, and its duplicate pass needs a
//     playlist that actually lists something twice.
//
// Applied ONLY when the launch environment asks for it, so every pre-existing suite
// sees the byte-identical fixture it saw before.
import Foundation
import GRDB
import Persistence

#if DEBUG
    enum AIContextualFixture {
        /// Launch-environment switch. Absent ⇒ this file changes nothing.
        static let environmentKey = "UITEST_SEED_AI_CONTEXT"
        /// The playlist the "Organize…" tests drive.
        static let playlistName = "Fixture Mix"
        /// A track whose file is gone, so the unavailable-seed path is reachable.
        static let missingTrackTitle = "Vanished Echo"
        /// A SECOND library row for the first fixture recording. Its title differs
        /// only in case, which ``SortKey`` folds away, so the duplicate pass groups
        /// the two while XCUITest can still address each row by its own label.
        static let duplicateTrackTitle = "AURORA ANTHEM"

        /// Gives the existing fixture tracks a real artist row, adds one `missing`
        /// track and one duplicate recording, and builds a playlist holding the
        /// duplicate alongside the original.
        static func seed(into database: AppDatabase) throws {
            try database.writer.write { db in
                var artist = ArtistRecord(name: "Fixture Artist", sortName: "fixture artist")
                try artist.insert(db)
                guard let artistId = artist.id else { return }
                let present = try TrackRecord.order(TrackRecord.Columns.id).fetchAll(db)
                for var track in present {
                    track.artistId = artistId
                    try track.update(db)
                }
                try insertMissingTrack(artistId: artistId, into: db)
                let duplicateId = try insertDuplicateTrack(of: present.first, artistId: artistId, into: db)
                let trailing = duplicateId.map { [$0] } ?? []
                try insertPlaylist(membership: present.compactMap(\.id) + trailing, into: db)
            }
        }

        /// A row that is the same recording as `original` — same folded title, same
        /// artist, same runtime — under a different path, which is exactly the shape
        /// `LibraryHygieneService` calls a duplicate.
        private static func insertDuplicateTrack(
            of original: TrackRecord?,
            artistId: Int64,
            into db: Database
        ) throws -> Int64? {
            guard let original else { return nil }
            var record = TrackRecord(
                filePath: "\(original.filePath).duplicate.mp3",
                title: duplicateTrackTitle,
                sortTitle: "zzz \(duplicateTrackTitle.lowercased())",
                artistName: original.artistName,
                duration: original.duration,
                availability: .present
            )
            record.artistId = artistId
            try record.insert(db)
            return record.id
        }

        /// No file is created for it: `availability` is the column the UI reads, and
        /// a row pointing at a path that does not exist is exactly the state the
        /// availability reconciler leaves behind when media vanishes.
        private static func insertMissingTrack(artistId: Int64, into db: Database) throws {
            var record = TrackRecord(
                filePath: "/nonexistent/\(missingTrackTitle).mp3",
                title: missingTrackTitle,
                sortTitle: missingTrackTitle.lowercased(),
                artistName: "Fixture Artist",
                duration: 90,
                availability: .missing
            )
            record.artistId = artistId
            try record.insert(db)
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
