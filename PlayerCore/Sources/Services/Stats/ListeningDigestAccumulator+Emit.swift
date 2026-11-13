// ListeningDigestAccumulator+Emit — rendering one window's accumulators as a digest.
//
// The single rule this file exists to enforce: **no array in the output ever inherits
// its order from a dictionary.** Swift's `Dictionary` iteration order depends on the
// hash seed, which is randomised per process, so emitting `tracks.map { … }` would
// produce a different byte sequence on every launch — the exact failure the digest's
// snapshot tests are built to catch.
//
// So every list is sorted with a TOTAL ordering before it is truncated: the primary
// metric descending, then the grouping key ascending. The key is unique inside each
// dictionary (it IS the dictionary key), so no two entries can compare equal and the
// result is a function of the values alone.
import Foundation

extension DigestWindowAccumulator {
    /// Renders the window. See ``ListeningWindowDigest`` for which facets include
    /// rollups and which are raw-events-only.
    func makeDigest() -> ListeningWindowDigest {
        let plays = rawPlays + rollupPlays
        let skips = rawSkips + rollupSkips
        let listened = rawListenedMicroseconds + rollupListenedMicroseconds
        let ranked = Array(orderedTracks().prefix(ListeningDigestBuilder.topEntityLimit))
        return ListeningWindowDigest(
            window: window,
            startedAt: Int64(startedAt.rounded(.down)),
            endedAt: Int64(endedAt.rounded(.down)),
            totalPlays: plays,
            totalListenedSeconds: StatsSeconds.seconds(fromMicroseconds: listened),
            skips: skips,
            skipRate: StatsRounding.ratio(Double(skips), over: Double(plays)),
            completions: rawCompletions + rollupCompletions,
            meanCompletion: meanCompletion,
            topTracks: ranked.map { Self.makeTrackStat(key: $0.key, entry: $0.value) },
            topArtists: Self.makeNameStats(artists),
            topGenres: Self.makeNameStats(genres),
            hourHistogram: hourHistogram,
            weekdayHistogram: weekdayHistogram,
            perTrackHours: includesPerTrackHours ? ranked.map { Self.makeTrackHours($0.key, $0.value) } : [],
            dayparts: makeDayparts()
        )
    }
}

// MARK: - Facet rendering

private extension DigestWindowAccumulator {
    /// Mean completion over RAW plays. Rollups keep completion COUNTS, not fractions,
    /// so folding them in would silently average a count against a fraction.
    var meanCompletion: Double {
        StatsRounding.ratio(
            StatsSeconds.seconds(fromMicroseconds: rawCompletionMicroseconds),
            over: Double(rawPlays)
        )
    }

    /// Tracks by plays descending, then identity key ascending. Total: the key is the
    /// dictionary key, so it is unique.
    func orderedTracks() -> [(key: String, value: DigestTrackAccumulator)] {
        tracks.sorted { lhs, rhs in
            lhs.value.plays == rhs.value.plays
                ? lhs.key < rhs.key
                : lhs.value.plays > rhs.value.plays
        }
    }

    static func makeIdentity(key: String, entry: DigestTrackAccumulator) -> ListeningTrackIdentity {
        var identity = ListeningTrackIdentity(
            artistName: entry.artistName,
            title: entry.title,
            albumTitle: entry.albumTitle,
            genre: entry.genre
        )
        // The grouping key is authoritative. Recomputing it from the merged snapshot
        // could disagree with it when two spellings collapsed, and every other facet
        // joins on the grouping key.
        identity.identityKey = key
        return identity
    }

    static func makeTrackStat(key: String, entry: DigestTrackAccumulator) -> ListeningTrackStat {
        ListeningTrackStat(
            track: makeIdentity(key: key, entry: entry),
            plays: entry.plays,
            skips: entry.skips,
            listenedSeconds: StatsSeconds.seconds(fromMicroseconds: entry.listenedMicroseconds),
            completions: entry.completions,
            meanCompletion: StatsRounding.ratio(
                StatsSeconds.seconds(fromMicroseconds: entry.completionMicroseconds),
                over: Double(entry.plays)
            ),
            lastPlayedAt: Int64(entry.lastPlayedAt.rounded(.down))
        )
    }

    static func makeTrackHours(_ key: String, _ entry: DigestTrackAccumulator) -> ListeningTrackHours {
        ListeningTrackHours(track: makeIdentity(key: key, entry: entry), hours: entry.hours)
    }

    /// Artists or genres by plays descending, then name ascending, capped at
    /// ``ListeningDigestBuilder/topEntityLimit``.
    static func makeNameStats(_ names: [String: DigestNameAccumulator]) -> [ListeningNameStat] {
        let ranked = names.sorted { lhs, rhs in
            lhs.value.plays == rhs.value.plays
                ? lhs.key < rhs.key
                : lhs.value.plays > rhs.value.plays
        }
        return ranked.prefix(ListeningDigestBuilder.topEntityLimit).map { key, entry in
            ListeningNameStat(
                name: key,
                plays: entry.plays,
                skips: entry.skips,
                listenedSeconds: StatsSeconds.seconds(fromMicroseconds: entry.listenedMicroseconds),
                completions: entry.completions,
                lastPlayedAt: entry.lastPlayedAt.map { Int64($0.rounded(.down)) }
            )
        }
    }

    func makeDayparts() -> [ListeningDaypartDigest] {
        ListeningDaypart.allCases.map { daypart in
            ListeningDaypartDigest(
                daypart: daypart,
                plays: daypart.hours.reduce(0) { $0 + hourHistogram[$1] },
                topTracks: daypartTracks(daypart)
            )
        }
    }

    /// A daypart's busiest tracks: plays inside its local hours descending, then
    /// identity key ascending. Tracks with no plays in the daypart are omitted rather
    /// than listed with a zero, so an empty daypart reads as empty.
    func daypartTracks(_ daypart: ListeningDaypart) -> [ListeningDaypartTrack] {
        let counted = tracks.map { key, entry in
            ListeningDaypartTrack(
                track: Self.makeIdentity(key: key, entry: entry),
                plays: daypart.hours.reduce(0) { $0 + entry.hours[$1] }
            )
        }
        let ranked = counted.filter { $0.plays > 0 }.sorted { lhs, rhs in
            lhs.plays == rhs.plays
                ? lhs.track.identityKey < rhs.track.identityKey
                : lhs.plays > rhs.plays
        }
        return Array(ranked.prefix(ListeningDigestBuilder.daypartTrackLimit))
    }
}
