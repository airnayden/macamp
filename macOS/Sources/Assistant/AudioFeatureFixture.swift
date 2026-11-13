// AudioFeatureFixture — a hermetically ANALYSED library, so the energy surfaces
// are reachable from a UI test.
//
// "Reorder by Energy" is gated on `MixRanking.energyArcCoverage` and the mix
// pipeline re-measures that coverage over the selection it is handed, so with no
// `trackAudioFeature` rows the item is correctly disabled and correctly proposes
// nothing. That made both halves of the reported bug untestable: a green
// "the item is disabled" assertion would equally describe the defect and the
// correct behaviour.
//
// Running the real pass is not an option — it decodes audio, and the fixture files
// are zero bytes. The rows are therefore written directly, with the CURRENT
// analysis version and each track's own `(fileSize, mtime)`, because
// `AudioFeatureCoverageReader` counts a row as coverage only when both match. A
// fixture that skipped the fingerprint would seed rows that every consumer reads as
// stale and would prove nothing.
//
// Energies ascend across the library so the arc has a real reordering to propose
// rather than the identity — an arc that changed nothing would surface as
// "already in energy order" and never reach the proposal sheet.
import Foundation
import GRDB
import Persistence
import Services

#if DEBUG
    enum AudioFeatureFixture {
        /// Launch-environment switch. Absent ⇒ this file changes nothing.
        static let environmentKey = "UITEST_SEED_AUDIO_FEATURES"

        /// What the seeded energies should make the arc DO.
        ///
        /// Two values of one key rather than two keys: both shapes describe the same
        /// fixture at full coverage, and the difference between them — whether the
        /// reorder has anything to propose — is exactly the distinction the
        /// "already in energy order" outcome exists to report.
        enum Shape: String {
            /// Energies ascend by track id, so the arc genuinely reorders.
            case reorderable = "1"
            /// Energies chosen so the arc reproduces the order the playlist is
            /// already in, making the reorder a no-op.
            case alreadyArced = "arced"
        }

        /// Writes a current, fingerprint-matching analysis row for every PRESENT
        /// track, so library coverage reads exactly `1`.
        ///
        /// `missing` rows are skipped deliberately: they are outside the population
        /// the pass walks and outside the coverage denominator, so seeding them
        /// would make the fixture disagree with the production reader.
        static func seed(into database: AppDatabase, shape: Shape) throws {
            try database.writer.write { db in
                let present = try TrackRecord
                    .filter(TrackRecord.Columns.availability == Availability.present.rawValue)
                    .order(TrackRecord.Columns.id)
                    .fetchAll(db)
                let ranks = energyRanks(count: present.count, shape: shape)
                for (index, track) in present.enumerated() {
                    guard let trackId = track.id else { continue }
                    try TrackAudioFeatureRecord(
                        trackId: trackId,
                        fileSize: track.fileSize ?? 0,
                        mtime: track.mtime ?? 0,
                        bpm: 100 + Double(index) * 5,
                        energy: energy(rank: ranks[index], of: present.count),
                        brightness: 0.5,
                        analysisVersion: AudioAnalysisService.analysisVersion,
                        computedAt: 0
                    ).upsert(db)
                }
            }
        }

        /// Each track's position in the ascending-energy ordering.
        ///
        /// `MixRanking.energyArced` sorts ascending and then DEALS — even indices
        /// build the rise, odd indices build the fall, which is appended reversed.
        /// So `reorderable` just ranks by id (the arc then permutes it), while
        /// `alreadyArced` inverts the deal: whichever ascending order deals back to
        /// `0, 1, 2, …` is the one that makes the arc the identity, and therefore
        /// makes `PlaylistOrganizeDiff` empty.
        static func energyRanks(count: Int, shape: Shape) -> [Int] {
            guard case .alreadyArced = shape else { return Array(0 ..< count) }
            var ranks = Array(repeating: 0, count: count)
            var rise = 0
            var fall = count - 1
            for position in 0 ..< count {
                if position.isMultiple(of: 2) {
                    ranks[rise] = position
                    rise += 1
                } else {
                    ranks[fall] = position
                    fall -= 1
                }
            }
            return ranks
        }

        /// Spreads ranks evenly across `0.1 ... 0.9`.
        static func energy(rank: Int, of count: Int) -> Double {
            guard count > 1 else { return 0.5 }
            return 0.1 + 0.8 * Double(rank) / Double(count - 1)
        }
    }
#endif
