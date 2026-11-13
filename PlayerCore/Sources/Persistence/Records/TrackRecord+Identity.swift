// TrackRecord+Identity — the composite `(filePath, cueStartFrame)` row identity.
//
// Migration v20 replaced the v1 column-level `UNIQUE(filePath)` with a table-level
// `UNIQUE(filePath, cueStartFrame)`, because one audio file named by a `.cue` sheet
// now backs N rows — one per cue segment. Every single-row lookup must therefore
// name BOTH halves, or it silently resolves to an arbitrary segment.
//
// This file is the one place that spelling lives, so the scanner's fingerprint-skip
// map, the repository's path lookups and any later consumer cannot drift apart.
import GRDB

public extension TrackRecord {
    /// The `cueStartFrame` an ordinary whole-file row carries — the `NOT NULL`
    /// column's SQL default, and the same sentinel
    /// ``TrackLoudnessFingerprint/wholeFileCueStartFrame`` has stored since v18.
    static let wholeFileCueStartFrame: Int64 = -1

    /// Whether this row is one segment of a `.cue` sheet rather than a whole file.
    var isCueSegment: Bool {
        cueStartFrame != Self.wholeFileCueStartFrame
    }

    /// The `UNIQUE(filePath, cueStartFrame)` key that identifies exactly one row.
    struct Identity: Hashable, Sendable {
        public let filePath: String
        public let cueStartFrame: Int64

        public init(filePath: String, cueStartFrame: Int64 = TrackRecord.wholeFileCueStartFrame) {
            self.filePath = filePath
            self.cueStartFrame = cueStartFrame
        }
    }

    var identity: Identity {
        Identity(filePath: filePath, cueStartFrame: cueStartFrame)
    }

    /// The single row `identity` names — the post-v20 replacement for a bare
    /// `filePath ==` filter wherever the caller genuinely wants one row.
    static func request(for identity: Identity) -> QueryInterfaceRequest<TrackRecord> {
        filter(Columns.filePath == identity.filePath)
            .filter(Columns.cueStartFrame == identity.cueStartFrame)
    }

    /// Every row backed by `filePath`, whole-file row first (its `-1` sorts below
    /// every real frame) then each cue segment in playing order.
    static func requestForAllRows(filePath: String) -> QueryInterfaceRequest<TrackRecord> {
        filter(Columns.filePath == filePath).order(Columns.cueStartFrame)
    }
}
