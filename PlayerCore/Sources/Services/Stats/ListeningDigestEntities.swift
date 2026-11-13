// ListeningDigestEntities — what a track, an artist and a genre look like in a digest.
//
// The load-bearing type here is ``ListeningTrackIdentity``. A row id is meaningless
// once a digest leaves the machine that produced it: rowids are assigned by the local
// SQLite, so the same song is `412` here and `7781` there, and an archive that keyed
// on them would silently attribute one listener's history to another's tracks. So the
// digest keys tracks on their own snapshot text instead:
//
//     identityKey = lowercased(artist) | lowercased(title) | lowercased(album)
//
// That key is what every track-level facet groups, joins and tie-breaks on — the
// windowed top-track lists, the daypart lists, the per-track hour histograms and the
// lifetime replay list alike — so a track means the same thing in all of them.
//
// `String.lowercased()` is the Unicode DEFAULT case mapping, not the locale-sensitive
// `lowercased(with:)`. That distinction is the whole reason the key is stable: under
// a Turkish locale a locale-aware mapping would fold `"I"` to `"ı"` and split one
// artist into two on a machine whose language happened to differ.
import Foundation

/// The portable identity of a track inside a digest: snapshot text, never a row id.
public struct ListeningTrackIdentity: Codable, Sendable, Equatable, Hashable {
    /// `lowercased(artist)|lowercased(title)|lowercased(album)`, with a missing field
    /// contributing an empty segment. The grouping and tie-break key for every
    /// track-level facet.
    public var identityKey: String
    /// Artist as snapshotted at capture, or `nil` when it was unknown.
    public var artistName: String?
    /// Title as snapshotted at capture.
    public var title: String?
    /// Album as snapshotted at capture.
    public var albumTitle: String?
    /// Genre as snapshotted at capture.
    public var genre: String?

    public init(artistName: String?, title: String?, albumTitle: String?, genre: String? = nil) {
        identityKey = Self.identityKey(artistName: artistName, title: title, albumTitle: albumTitle)
        self.artistName = artistName
        self.title = title
        self.albumTitle = albumTitle
        self.genre = genre
    }

    /// Builds the canonical key. The single definition — every caller routes here so
    /// two facets can never disagree about whether two rows are the same track.
    public static func identityKey(artistName: String?, title: String?, albumTitle: String?) -> String {
        let artist = artistName?.lowercased() ?? ""
        let name = title?.lowercased() ?? ""
        let album = albumTitle?.lowercased() ?? ""
        return "\(artist)|\(name)|\(album)"
    }
}

/// One track's statistics inside a window. Raw events only.
public struct ListeningTrackStat: Codable, Sendable, Equatable {
    public var track: ListeningTrackIdentity
    /// Plays in the window.
    public var plays: Int
    /// Plays cut short.
    public var skips: Int
    /// Seconds actually heard, summed as whole microseconds.
    public var listenedSeconds: Double
    /// Plays that reached ``PlayEventCompactor/completionThreshold``.
    public var completions: Int
    /// Mean completion fraction, rounded to ``StatsRounding/fractionDigits``.
    public var meanCompletion: Double
    /// Recency: the most recent play's start, in whole epoch seconds.
    public var lastPlayedAt: Int64

    public init(
        track: ListeningTrackIdentity,
        plays: Int = 0,
        skips: Int = 0,
        listenedSeconds: Double = 0,
        completions: Int = 0,
        meanCompletion: Double = 0,
        lastPlayedAt: Int64 = 0
    ) {
        self.track = track
        self.plays = plays
        self.skips = skips
        self.listenedSeconds = listenedSeconds
        self.completions = completions
        self.meanCompletion = meanCompletion
        self.lastPlayedAt = lastPlayedAt
    }
}

/// One artist or genre inside a window. Raw ∪ rollups.
public struct ListeningNameStat: Codable, Sendable, Equatable {
    /// The artist or genre exactly as snapshotted, or `""` when it was unknown.
    ///
    /// Deliberately NOT case-folded: this is the same key
    /// `playEventRollup.artistKey` / `genreKey` uses, and the union of raw events
    /// with rollups only lines up if both sides group on the identical string.
    public var name: String
    /// Plays attributed to this name.
    public var plays: Int
    /// Plays cut short.
    public var skips: Int
    /// Seconds actually heard, summed as whole microseconds.
    public var listenedSeconds: Double
    /// Plays that reached ``PlayEventCompactor/completionThreshold``.
    public var completions: Int
    /// Recency: the most recent RAW play's start, in whole epoch seconds, or `nil`
    /// when only rollups contributed — a rollup keeps no timestamp to report.
    public var lastPlayedAt: Int64?

    public init(
        name: String,
        plays: Int = 0,
        skips: Int = 0,
        listenedSeconds: Double = 0,
        completions: Int = 0,
        lastPlayedAt: Int64? = nil
    ) {
        self.name = name
        self.plays = plays
        self.skips = skips
        self.listenedSeconds = listenedSeconds
        self.completions = completions
        self.lastPlayedAt = lastPlayedAt
    }
}

/// A track's plays split across the local hours of a window. Raw events only.
public struct ListeningTrackHours: Codable, Sendable, Equatable {
    public var track: ListeningTrackIdentity
    /// Exactly ``ListeningLocalTime/hoursPerDay`` bins, index `0` = midnight local.
    public var hours: [Int]

    public init(track: ListeningTrackIdentity, hours: [Int]) {
        self.track = track
        self.hours = hours
    }
}

/// A track inside one daypart list — plays only, because the digest keeps no
/// per-hour seconds and reporting a window-wide figure beside a daypart-scoped count
/// would invite exactly the wrong reading.
public struct ListeningDaypartTrack: Codable, Sendable, Equatable {
    public var track: ListeningTrackIdentity
    /// Plays that started inside this daypart.
    public var plays: Int

    public init(track: ListeningTrackIdentity, plays: Int) {
        self.track = track
        self.plays = plays
    }
}

/// One `playSegmentHeat` row, scored. A LIFETIME entity: heat is an aggregate with no
/// timestamps, so it is never windowed and never aged.
public struct ReplayHeatDigest: Codable, Sendable, Equatable {
    public var track: ListeningTrackIdentity
    /// The length the relative buckets were measured against.
    public var durationSeconds: Double
    /// Committed listening passes folded into this heatmap.
    public var totalPasses: Int
    /// Sum of every bucket, as `UInt64` — a bucket saturates at `UInt32.max`.
    public var totalListens: UInt64
    /// See ``ReplayHeatAnalysis/replayAffinity(_:)``.
    public var replayAffinity: Double
    /// At most ``ReplayHeatAnalysis/clusterLimit`` hot passages, ordered by intensity
    /// descending then start ascending.
    public var clusters: [ReplayCluster]

    public init(
        track: ListeningTrackIdentity,
        durationSeconds: Double,
        totalPasses: Int,
        totalListens: UInt64,
        replayAffinity: Double,
        clusters: [ReplayCluster]
    ) {
        self.track = track
        self.durationSeconds = durationSeconds
        self.totalPasses = totalPasses
        self.totalListens = totalListens
        self.replayAffinity = replayAffinity
        self.clusters = clusters
    }
}
