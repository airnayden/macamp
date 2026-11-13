// ListeningWindowDigest — the facets of one span, plus the daypart split.
//
// Read the horizon table in `ListeningDigest.swift` before trusting any single
// number here: within one window, some figures include monthly rollups and some are
// raw-events-only, because a rollup carries no track identity, no timestamps and no
// completion fractions. The doc comment on each property says which it is.
import Foundation

/// A named block of local hours, used to split a window by time of day.
public enum ListeningDaypart: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
    /// Local hours 00–05.
    case night
    /// Local hours 06–11.
    case morning
    /// Local hours 12–17.
    case afternoon
    /// Local hours 18–23.
    case evening

    /// The local hours this daypart covers. The four ranges tile `0 ... 23` exactly
    /// once, so every event lands in exactly one daypart.
    public var hours: ClosedRange<Int> {
        switch self {
        case .night: 0 ... 5
        case .morning: 6 ... 11
        case .afternoon: 12 ... 17
        case .evening: 18 ... 23
        }
    }
}

/// What a profile played during one daypart of one window. Raw events only.
public struct ListeningDaypartDigest: Codable, Sendable, Equatable {
    public var daypart: ListeningDaypart
    /// Plays that started in this daypart's local hours.
    public var plays: Int
    /// The daypart's busiest tracks, at most
    /// ``ListeningDigestBuilder/daypartTrackLimit``, ordered by plays descending then
    /// identity ascending.
    public var topTracks: [ListeningDaypartTrack]

    public init(daypart: ListeningDaypart, plays: Int = 0, topTracks: [ListeningDaypartTrack] = []) {
        self.daypart = daypart
        self.plays = plays
        self.topTracks = topTracks
    }
}

/// Every facet computed over one ``ListeningWindowKind``.
public struct ListeningWindowDigest: Codable, Sendable, Equatable {
    public var window: ListeningWindowKind

    /// Inclusive lower bound of the window, in whole epoch seconds. `0` for
    /// ``ListeningWindowKind/allTime``, which spans all retained history.
    public var startedAt: Int64

    /// Inclusive upper bound — always the digest's reference instant, so an event
    /// dated in the future belongs to no window.
    public var endedAt: Int64

    /// Plays in the window. Raw ∪ rollups.
    public var totalPlays: Int

    /// Seconds actually heard, summed as whole microseconds. Raw ∪ rollups.
    public var totalListenedSeconds: Double

    /// Plays the listener cut short. Raw ∪ rollups.
    public var skips: Int

    /// ``skips`` over ``totalPlays``, rounded to
    /// ``StatsRounding/fractionDigits``. Raw ∪ rollups.
    public var skipRate: Double

    /// Plays whose completion reached ``PlayEventCompactor/completionThreshold``.
    /// Raw ∪ rollups — and it uses that exact shared constant, so a track's
    /// completion rate does not step the month its events cross the rollup horizon.
    public var completions: Int

    /// Mean completion fraction, rounded to ``StatsRounding/fractionDigits``.
    /// **RAW events only** — rollups keep counts, not fractions.
    public var meanCompletion: Double

    /// Busiest tracks, at most ``ListeningDigestBuilder/topEntityLimit``, ordered by
    /// plays descending then identity ascending. **RAW events only.**
    public var topTracks: [ListeningTrackStat]

    /// Busiest artists, at most ``ListeningDigestBuilder/topEntityLimit``, ordered by
    /// plays descending then name ascending. Raw ∪ rollups.
    public var topArtists: [ListeningNameStat]

    /// Busiest genres, same shape and ordering as ``topArtists``. Raw ∪ rollups.
    public var topGenres: [ListeningNameStat]

    /// Plays per local hour, exactly ``ListeningLocalTime/hoursPerDay`` bins.
    /// **RAW events only** — a rollup has no timestamp to bucket.
    public var hourHistogram: [Int]

    /// Plays per local weekday, exactly ``ListeningLocalTime/daysPerWeek`` bins,
    /// index `0` = Sunday. **RAW events only.**
    public var weekdayHistogram: [Int]

    /// A 24-bin local-hour histogram for each of ``topTracks``, in the same order.
    /// Populated only for ``ListeningWindowKind/last30Days`` and
    /// ``ListeningWindowKind/last12Months``; empty elsewhere. **RAW events only.**
    public var perTrackHours: [ListeningTrackHours]

    /// One entry per ``ListeningDaypart``, in that enum's declaration order.
    /// **RAW events only.**
    public var dayparts: [ListeningDaypartDigest]

    public init(
        window: ListeningWindowKind,
        startedAt: Int64 = 0,
        endedAt: Int64 = 0,
        totalPlays: Int = 0,
        totalListenedSeconds: Double = 0,
        skips: Int = 0,
        skipRate: Double = 0,
        completions: Int = 0,
        meanCompletion: Double = 0,
        topTracks: [ListeningTrackStat] = [],
        topArtists: [ListeningNameStat] = [],
        topGenres: [ListeningNameStat] = [],
        hourHistogram: [Int] = [],
        weekdayHistogram: [Int] = [],
        perTrackHours: [ListeningTrackHours] = [],
        dayparts: [ListeningDaypartDigest] = []
    ) {
        self.window = window
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalPlays = totalPlays
        self.totalListenedSeconds = totalListenedSeconds
        self.skips = skips
        self.skipRate = skipRate
        self.completions = completions
        self.meanCompletion = meanCompletion
        self.topTracks = topTracks
        self.topArtists = topArtists
        self.topGenres = topGenres
        self.hourHistogram = hourHistogram
        self.weekdayHistogram = weekdayHistogram
        self.perTrackHours = perTrackHours
        self.dayparts = dayparts
    }
}
