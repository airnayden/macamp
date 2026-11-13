// ListeningDigest — a versioned, deterministic, survivable summary of a profile's
// listening.
//
// Three properties define this type, and every design choice below serves one of
// them:
//
//  1. **Survivable.** Every figure comes from `playEvent` snapshots, `playEventRollup`
//     and `playSegmentHeat` — tables that carry their own denormalised metadata.
//     Nothing here joins `track`, `playlist` or any other library table, so deleting
//     a file, a folder or the whole library changes not one byte of the digest.
//  2. **Deterministic.** Two machines holding the same rows must produce byte-identical
//     JSON. That means: no `Calendar`, no `TimeZone`, no `Locale`; sums quantized to
//     integers before adding (``StatsSeconds``); fractions rounded at one fixed
//     precision (``StatsRounding``); a TOTAL ordering on every array; and
//     `JSONEncoder.outputFormatting = [.sortedKeys]`.
//  3. **Portable.** No local row id appears anywhere in the output. Tracks are
//     identified by ``ListeningTrackIdentity/identityKey``, derived from the snapshot
//     text, so a digest still means the same thing after being exported from one
//     machine and imported into another whose rowids are entirely different.
//
// ## Per-facet horizons
//
// Raw events age into monthly rollups after 24 months
// (``PlayEventCompactor/horizonMonths``), and a rollup keeps only
// `(artist, genre, plays, listenedSeconds, skips, completions)` — no track identity,
// no timestamps, no completion fractions. The digest is honest about that rather
// than pretending otherwise:
//
// | Facet | Source |
// |---|---|
// | `topArtists`, `topGenres`, `totalPlays`, `totalListenedSeconds`, `skips`, `skipRate`, `completions` | raw ∪ rollups
// (rollups only reach the `allTime` window) |
// | `topTracks`, `perTrackHours`, `dayparts`, `hourHistogram`, `weekdayHistogram`, `meanCompletion`, per-track recency
// | RAW events only — bounded by ``ListeningDigest/rawHorizonYearMonth`` |
// | `mostReplayed` | `playSegmentHeat` alone — a LIFETIME facet with no window semantics, because heat is an aggregate
// that is never aged |
//
// The raw ∪ rollup union cannot double-count: the compactor's postcondition is that
// a civil month is either entirely raw or entirely rolled up, never both.
import Foundation
import Persistence

/// The spans a digest reports on, in the order they appear in
/// ``ListeningDigest/windows``.
public enum ListeningWindowKind: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    /// The seven days ending at the digest's reference instant.
    case last7Days
    /// The thirty days ending at the digest's reference instant.
    case last30Days
    /// The twelve civil months ending with the reference instant's own month.
    case last12Months
    /// Everything the database still holds.
    case allTime
}

/// A versioned summary of one profile's listening, safe to archive and compare.
public struct ListeningDigest: Codable, Sendable, Equatable {
    /// The schema version of this payload. Every facet below shipped in version 1;
    /// a consumer that does not recognise the value should refuse the digest rather
    /// than guess at it.
    public static let currentVersion = 1

    /// See ``currentVersion``.
    public var digestVersion: Int

    /// The reference instant every window is measured back from, in whole epoch
    /// seconds. A digest is a pure function of `(rows, this instant)`.
    public var generatedAt: Int64

    /// The first civil month, `"YYYY-MM"`, still held as RAW events — everything
    /// before it survives only as rollups. Published so a reader can see exactly how
    /// far back the track-level and hour-level facets can possibly reach.
    public var rawHorizonYearMonth: String

    /// One entry per ``ListeningWindowKind``, in that enum's declaration order.
    public var windows: [ListeningWindowDigest]

    /// The profile's most obsessively replayed tracks — a LIFETIME list drawn from
    /// `playSegmentHeat` alone, independent of ``windows``.
    ///
    /// At most 25 entries, each clearing
    /// ``ReplayHeatAnalysis/hasTrustworthyShape(totalPasses:buckets:)``, ordered by
    /// ``ReplayHeatDigest/replayAffinity`` descending, then
    /// ``ReplayHeatDigest/totalPasses`` descending, then identity ascending.
    public var mostReplayed: [ReplayHeatDigest]

    public init(
        digestVersion: Int = ListeningDigest.currentVersion,
        generatedAt: Int64 = 0,
        rawHorizonYearMonth: String = "",
        windows: [ListeningWindowDigest] = [],
        mostReplayed: [ReplayHeatDigest] = []
    ) {
        self.digestVersion = digestVersion
        self.generatedAt = generatedAt
        self.rawHorizonYearMonth = rawHorizonYearMonth
        self.windows = windows
        self.mostReplayed = mostReplayed
    }
}

// MARK: - Deterministic coding

public extension ListeningDigest {
    /// The ONE encoder configuration a digest may be written with.
    ///
    /// `.sortedKeys` is what makes the output a function of the values rather than of
    /// Swift's dictionary/key emission order, and it is why two digests over the same
    /// rows can be compared as bytes. Nothing else is set: pretty-printing, slash
    /// escaping and any date strategy would all be free variables, and a digest that
    /// only matches when both sides happened to pick the same ones is not a contract.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The decoder that reads what ``makeEncoder()`` wrote.
    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// This digest as canonical JSON.
    func encodedJSON() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Reads a digest back from ``encodedJSON()``.
    static func decoded(from data: Data) throws -> ListeningDigest {
        try makeDecoder().decode(ListeningDigest.self, from: data)
    }

    /// The window with the given kind, or `nil` when it is absent.
    func window(_ kind: ListeningWindowKind) -> ListeningWindowDigest? {
        windows.first { $0.window == kind }
    }
}
