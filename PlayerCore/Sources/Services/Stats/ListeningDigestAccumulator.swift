// ListeningDigestAccumulator — the streaming reduction behind one digest window.
//
// The builder walks `playEvent` and `playEventRollup` in keyset pages and folds each
// row into every window at once. Nothing is ever materialised as a list of events:
// what stays resident is one accumulator per distinct track, artist and genre, which
// is bounded by the profile's library rather than by how much it has been played.
//
// Every field here is folded with an ORDER-INDEPENDENT operation, which is what makes
// the digest a function of the SET of rows rather than of the order SQLite happened
// to return them in:
//
//  * counters use integer `+`;
//  * seconds and completion fractions are quantized to millionths (``StatsSeconds``)
//    BEFORE summing, because `Double` addition is not associative;
//  * recency uses `max`;
//  * a disagreeing metadata snapshot resolves with `min`, so two spellings of the
//    same artist always collapse the same way (see ``DigestTrackAccumulator/merged``).
//
// Fractions borrow the seconds quantizer on purpose: it is exactly "scale by a
// million, round, keep an integer", which is as correct for a `0 ... 1` completion
// fraction as it is for a duration, and it means there is one quantization rule in
// the codebase rather than two that could drift.
import Foundation
import Persistence

/// One event's contribution, pre-quantized so every window folds identical integers.
struct DigestContribution {
    var skips: Int
    var completions: Int
    var listenedMicroseconds: Int64
    var completionMicroseconds: Int64
    var startedAt: Double
}

/// Per-track running totals inside one window.
struct DigestTrackAccumulator {
    var artistName: String?
    var title: String?
    var albumTitle: String?
    var genre: String?
    var plays = 0
    var skips = 0
    var completions = 0
    var listenedMicroseconds: Int64 = 0
    var completionMicroseconds: Int64 = 0
    /// Most recent play start. `0` is a safe floor: the digest's domain invariant is
    /// that no event predates the epoch.
    var lastPlayedAt: Double = 0
    var hours = [Int](repeating: 0, count: ListeningLocalTime.hoursPerDay)

    /// Resolves two snapshots of the same field.
    ///
    /// `identityKey` case-folds artist, title and album, so two events can legitimately
    /// group together while spelling a field differently ("REM" vs "R.E.M." never, but
    /// "Beatles" vs "BEATLES" easily) — and `genre` is not part of the key at all, so
    /// it can differ outright. Taking the lexicographically smaller non-`nil` value is
    /// a total, order-independent rule: whichever page the rows arrive in, the winner
    /// is the same.
    static func merged(_ current: String?, _ incoming: String?) -> String? {
        guard let incoming else { return current }
        guard let current else { return incoming }
        return min(current, incoming)
    }
}

/// Per-artist / per-genre running totals inside one window.
struct DigestNameAccumulator {
    var plays = 0
    var skips = 0
    var completions = 0
    var listenedMicroseconds: Int64 = 0
    /// `nil` until a RAW event contributes — rollups carry no timestamp.
    var lastPlayedAt: Double?
}

/// Everything one ``ListeningWindowKind`` accumulates before it is rendered.
struct DigestWindowAccumulator {
    let window: ListeningWindowKind
    /// Inclusive lower bound in epoch seconds.
    let startedAt: Double
    /// Inclusive upper bound in epoch seconds — the digest's reference instant.
    let endedAt: Double
    /// Whether monthly rollups reach this window. Only ``ListeningWindowKind/allTime``
    /// does: a rollup is by definition older than the 24-month raw horizon, so it can
    /// never fall inside the 7-day, 30-day or 12-month spans.
    let includesRollups: Bool
    /// Whether ``ListeningWindowDigest/perTrackHours`` is published for this window.
    let includesPerTrackHours: Bool

    var rawPlays = 0
    var rawSkips = 0
    var rawCompletions = 0
    var rawListenedMicroseconds: Int64 = 0
    var rawCompletionMicroseconds: Int64 = 0
    var rollupPlays = 0
    var rollupSkips = 0
    var rollupCompletions = 0
    var rollupListenedMicroseconds: Int64 = 0
    var hourHistogram = [Int](repeating: 0, count: ListeningLocalTime.hoursPerDay)
    var weekdayHistogram = [Int](repeating: 0, count: ListeningLocalTime.daysPerWeek)
    var tracks: [String: DigestTrackAccumulator] = [:]
    var artists: [String: DigestNameAccumulator] = [:]
    var genres: [String: DigestNameAccumulator] = [:]
}

// MARK: - Folding rows in

extension DigestWindowAccumulator {
    /// Folds one raw play event in, if it falls inside the window.
    ///
    /// An event dated after the reference instant belongs to no window, including
    /// `allTime` — "everything up to now" is the only reading under which a digest
    /// generated from a fixed clock is reproducible.
    mutating func ingest(_ event: PlayEventRecord) {
        guard event.startedAt >= startedAt, event.startedAt <= endedAt else { return }
        let completed = event.completionFraction >= PlayEventCompactor.completionThreshold
        let contribution = DigestContribution(
            skips: event.skipped ? 1 : 0,
            completions: completed ? 1 : 0,
            listenedMicroseconds: StatsSeconds.microseconds(fromSeconds: event.secondsListened),
            completionMicroseconds: StatsSeconds.microseconds(fromSeconds: event.completionFraction),
            startedAt: event.startedAt
        )
        let hour = ListeningLocalTime.hourOfDay(
            startedAt: event.startedAt,
            utcOffsetSeconds: event.utcOffsetSeconds
        )
        let weekday = ListeningLocalTime.weekday(
            startedAt: event.startedAt,
            utcOffsetSeconds: event.utcOffsetSeconds
        )

        rawPlays += 1
        rawSkips += contribution.skips
        rawCompletions += contribution.completions
        rawListenedMicroseconds += contribution.listenedMicroseconds
        rawCompletionMicroseconds += contribution.completionMicroseconds
        hourHistogram[hour] += 1
        weekdayHistogram[weekday] += 1

        ingestTrack(event, hour: hour, contribution: contribution)
        Self.ingestName(into: &artists, key: event.artistName ?? Self.unknownKey, contribution: contribution)
        Self.ingestName(into: &genres, key: event.genre ?? Self.unknownKey, contribution: contribution)
    }

    /// Folds one monthly rollup in.
    ///
    /// Safe to add unconditionally to the `allTime` totals: the compactor guarantees a
    /// civil month is either entirely raw or entirely rolled up, so a rollup can never
    /// describe a play that is also still present as an event.
    mutating func ingest(_ rollup: PlayEventRollupRecord) {
        guard includesRollups else { return }
        rollupPlays += rollup.plays
        rollupSkips += rollup.skips
        rollupCompletions += rollup.completions
        rollupListenedMicroseconds += StatsSeconds.microseconds(fromSeconds: rollup.listenedSeconds)
        Self.ingestRollup(into: &artists, key: rollup.artistKey, rollup: rollup)
        Self.ingestRollup(into: &genres, key: rollup.genreKey, rollup: rollup)
    }
}

// MARK: - Grouping

private extension DigestWindowAccumulator {
    /// The empty-string sentinel `playEventRollup` uses for an unknown artist or
    /// genre. Raw events must collapse `nil` to the SAME value or the two sides of the
    /// union would land in different buckets.
    static var unknownKey: String {
        PlayEventRollupRecord.unknownKey
    }

    mutating func ingestTrack(_ event: PlayEventRecord, hour: Int, contribution: DigestContribution) {
        let key = ListeningTrackIdentity.identityKey(
            artistName: event.artistName,
            title: event.title,
            albumTitle: event.albumTitle
        )
        var entry = tracks[key] ?? DigestTrackAccumulator()
        entry.artistName = DigestTrackAccumulator.merged(entry.artistName, event.artistName)
        entry.title = DigestTrackAccumulator.merged(entry.title, event.title)
        entry.albumTitle = DigestTrackAccumulator.merged(entry.albumTitle, event.albumTitle)
        entry.genre = DigestTrackAccumulator.merged(entry.genre, event.genre)
        entry.plays += 1
        entry.skips += contribution.skips
        entry.completions += contribution.completions
        entry.listenedMicroseconds += contribution.listenedMicroseconds
        entry.completionMicroseconds += contribution.completionMicroseconds
        entry.lastPlayedAt = max(entry.lastPlayedAt, contribution.startedAt)
        entry.hours[hour] += 1
        tracks[key] = entry
    }

    static func ingestName(
        into names: inout [String: DigestNameAccumulator],
        key: String,
        contribution: DigestContribution
    ) {
        var entry = names[key] ?? DigestNameAccumulator()
        entry.plays += 1
        entry.skips += contribution.skips
        entry.completions += contribution.completions
        entry.listenedMicroseconds += contribution.listenedMicroseconds
        entry.lastPlayedAt = max(entry.lastPlayedAt ?? contribution.startedAt, contribution.startedAt)
        names[key] = entry
    }

    static func ingestRollup(
        into names: inout [String: DigestNameAccumulator],
        key: String,
        rollup: PlayEventRollupRecord
    ) {
        var entry = names[key] ?? DigestNameAccumulator()
        entry.plays += rollup.plays
        entry.skips += rollup.skips
        entry.completions += rollup.completions
        entry.listenedMicroseconds += StatsSeconds.microseconds(fromSeconds: rollup.listenedSeconds)
        names[key] = entry
    }
}
