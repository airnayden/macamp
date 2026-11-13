// ListeningDigestBuilder — assembles a ``ListeningDigest`` from three tables.
//
// The build is three keyset-paged scans folded into four window accumulators, and
// nothing else. In particular there is **no join against `track`, `playlist` or any
// other library table** — the survivability invariant, and the single most important
// constraint on this file. Every field the digest publishes is read from a snapshot
// column on `playEvent`, `playEventRollup` or `playSegmentHeat`, all of which
// deliberately carry their own denormalised metadata so they outlive the rows they
// came from.
//
// Determinism comes from four properties, each of which is separately testable:
//
//  1. **Total scan order.** Every repository read is keyset-paginated with an `id`
//     tie-break, so the same rows arrive in the same sequence whatever the page size.
//  2. **Order-independent folding.** See `ListeningDigestAccumulator.swift` — integer
//     sums, `max` for recency, `min` for disagreeing snapshots. Together with (1) this
//     is what makes a reversed insertion order produce identical bytes.
//  3. **Total output ordering.** Every emitted array is sorted on a key that is unique
//     within its collection, so nothing inherits `Dictionary` iteration order.
//  4. **No ambient inputs.** The clock is injected; hours come from each event's
//     stored `utcOffsetSeconds`; there is no `Calendar`, `TimeZone`, `Locale` or
//     `DateFormatter` anywhere in the digest sources. Changing the process time zone
//     or locale cannot move a single byte.
import Foundation
import Persistence

/// Builds a versioned listening digest for one profile.
public protocol ListeningDigestBuilding: Sendable {
    /// Reads the profile's history and renders it as a ``ListeningDigest``.
    func buildDigest(profileId: Int64) async throws -> ListeningDigest
}

/// The production ``ListeningDigestBuilding`` over the v15 statistics tables.
public struct ListeningDigestBuilder: ListeningDigestBuilding {
    /// Entries kept in each window's top-track, top-artist and top-genre list. 25
    /// matches the precedent the stats screen already sets.
    public static let topEntityLimit = 25

    /// Entries kept in each daypart list.
    public static let daypartTrackLimit = 10

    /// Entries kept in ``ListeningDigest/mostReplayed``.
    public static let replayEntityLimit = 25

    /// Committed listening passes that on their own qualify a heatmap as a replay.
    /// A heatmap below this still qualifies when one 1% slice was heard often enough
    /// — see ``ReplayHeatAnalysis/hasTrustworthyShape(totalPasses:buckets:)``.
    public static let minimumReplayPasses = ReplayHeatAnalysis.minimumTrustedPasses

    /// Days in the ``ListeningWindowKind/last7Days`` window.
    static let shortWindowDays: Double = 7
    /// Days in the ``ListeningWindowKind/last30Days`` window.
    static let mediumWindowDays: Double = 30
    /// Whole months to reach back for ``ListeningWindowKind/last12Months``: the
    /// reference month plus eleven before it.
    static let longWindowMonthsBack = 11

    private let events: any PlayEventRepositoryProviding
    private let heat: any PlaySegmentHeatRepositoryProviding
    private let now: @Sendable () -> Date
    private let pageSize: Int

    /// - Parameters:
    ///   - events: Windowed access to `playEvent` and `playEventRollup`.
    ///   - heat: Windowed access to `playSegmentHeat`.
    ///   - now: The reference clock every window is measured back from. Injected so a
    ///     test can place "now" on a boundary without waiting for real time.
    ///   - pageSize: Rows per keyset page. A free parameter precisely so a test can
    ///     prove the output does not depend on it.
    public init(
        events: any PlayEventRepositoryProviding,
        heat: any PlaySegmentHeatRepositoryProviding,
        now: @escaping @Sendable () -> Date = { Date() },
        pageSize: Int = PlayEventRepository.fetchLimit
    ) {
        self.events = events
        self.heat = heat
        self.now = now
        self.pageSize = max(1, pageSize)
    }

    /// Convenience over the application database.
    public init(
        _ appDatabase: AppDatabase,
        now: @escaping @Sendable () -> Date = { Date() },
        pageSize: Int = PlayEventRepository.fetchLimit
    ) {
        self.init(
            events: PlayEventRepository(appDatabase),
            heat: PlaySegmentHeatRepository(appDatabase),
            now: now,
            pageSize: pageSize
        )
    }

    public func buildDigest(profileId: Int64) async throws -> ListeningDigest {
        let reference = now()
        let referenceSeconds = reference.timeIntervalSince1970
        var windows = Self.makeWindows(now: referenceSeconds)
        try await ingestEvents(profileId: profileId, into: &windows)
        try await ingestRollups(profileId: profileId, into: &windows)
        let replayed = try await makeMostReplayed(profileId: profileId)
        let horizon = PlayEventCompactor.horizonMonthIndex(now: reference)
        return ListeningDigest(
            digestVersion: ListeningDigest.currentVersion,
            generatedAt: Int64(referenceSeconds.rounded(.down)),
            rawHorizonYearMonth: CivilMonth.yearMonthKey(atIndex: horizon),
            windows: windows.map { $0.makeDigest() },
            mostReplayed: replayed
        )
    }
}

// MARK: - Windows

extension ListeningDigestBuilder {
    /// One accumulator per ``ListeningWindowKind``, in declaration order.
    ///
    /// Only `allTime` takes rollups: every rollup is older than the compactor's
    /// 24-month horizon, so it cannot fall inside any of the shorter spans.
    static func makeWindows(now reference: Double) -> [DigestWindowAccumulator] {
        ListeningWindowKind.allCases.map { kind in
            DigestWindowAccumulator(
                window: kind,
                startedAt: windowStart(kind, now: reference),
                endedAt: reference,
                includesRollups: kind == .allTime,
                includesPerTrackHours: kind == .last30Days || kind == .last12Months
            )
        }
    }

    /// The inclusive lower bound of a window.
    ///
    /// The twelve-month span is measured in CIVIL months through ``CivilMonth`` — the
    /// same helper the compactor derives its horizon and its `yearMonth` keys from —
    /// rather than as 365 days, so "the last twelve months" names whole months and
    /// cannot drift against the rollup boundary. The day-based spans need no calendar
    /// at all.
    static func windowStart(_ kind: ListeningWindowKind, now reference: Double) -> Double {
        switch kind {
        case .last7Days:
            max(0, reference - shortWindowDays * ListeningLocalTime.secondsPerDay)
        case .last30Days:
            max(0, reference - mediumWindowDays * ListeningLocalTime.secondsPerDay)
        case .last12Months:
            max(0, CivilMonth.startOfMonthEpochSeconds(
                atIndex: CivilMonth.monthIndex(fromEpochSeconds: reference) - longWindowMonthsBack
            ))
        case .allTime:
            0
        }
    }
}

// MARK: - Paged scans

private extension ListeningDigestBuilder {
    func ingestEvents(profileId: Int64, into windows: inout [DigestWindowAccumulator]) async throws {
        var cursor: PageCursor<Double>?
        repeat {
            let page = try await events.playEvents(profileId: profileId, before: cursor, limit: pageSize)
            for event in page.items {
                for index in windows.indices {
                    windows[index].ingest(event)
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
    }

    func ingestRollups(profileId: Int64, into windows: inout [DigestWindowAccumulator]) async throws {
        var cursor: PageCursor<String>?
        repeat {
            let page = try await events.rollups(profileId: profileId, after: cursor, limit: pageSize)
            for rollup in page.items {
                for index in windows.indices {
                    windows[index].ingest(rollup)
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
    }

    /// The lifetime replay list. Reads `playSegmentHeat` alone: heat is an aggregate
    /// with no timestamps, so it has no window semantics and is never aged.
    func makeMostReplayed(profileId: Int64) async throws -> [ReplayHeatDigest] {
        var candidates: [RankedReplay] = []
        var cursor: PageCursor<Int64>?
        repeat {
            let page = try await heat.allSegmentHeat(profileId: profileId, after: cursor, limit: pageSize)
            for record in page.items {
                guard let ranked = try Self.makeRankedReplay(record) else { continue }
                candidates.append(ranked)
            }
            cursor = page.nextCursor
        } while cursor != nil
        return Self.ranked(candidates)
    }
}

// MARK: - Replay ranking

/// A replay entry paired with the string that makes its ordering total.
///
/// Two heatmaps can share an `identityKey` — the same song imported twice sits in two
/// rows — so affinity, passes and identity alone are not a total order. The tie-break
/// concatenates every remaining field the entry encodes, which means two entries that
/// still compare equal are byte-identical and their relative order cannot change the
/// output. Row ids are deliberately NOT used: they are machine-local.
private struct RankedReplay {
    let entry: ReplayHeatDigest
    let tieBreak: String
}

private extension ListeningDigestBuilder {
    /// Below every printable character, so the joined string orders exactly as the
    /// tuple of its components would.
    static let fieldSeparator = "\u{1}"

    /// `nil` when the heatmap does not clear the trust floor. Decoding precedes the
    /// floor because the floor's peak half is a fact about the buckets.
    static func makeRankedReplay(_ record: PlaySegmentHeatRecord) throws -> RankedReplay? {
        let buckets = try record.decodedBuckets()
        guard ReplayHeatAnalysis.hasTrustworthyShape(
            totalPasses: record.totalPasses,
            buckets: buckets
        ) else { return nil }
        let entry = ReplayHeatDigest(
            track: ListeningTrackIdentity(
                artistName: record.artistName,
                title: record.title,
                albumTitle: record.albumTitle,
                genre: record.genre
            ),
            durationSeconds: record.durationSeconds,
            totalPasses: record.totalPasses,
            totalListens: ReplayHeatAnalysis.totalCount(buckets),
            replayAffinity: ReplayHeatAnalysis.replayAffinity(buckets),
            clusters: ReplayHeatAnalysis.clusters(buckets)
        )
        return RankedReplay(entry: entry, tieBreak: tieBreak(entry))
    }

    static func tieBreak(_ entry: ReplayHeatDigest) -> String {
        let clusters = entry.clusters
            .map { "\($0.startPercent)-\($0.endPercent)-\($0.intensity)" }
            .joined(separator: ",")
        return [
            entry.track.identityKey,
            entry.track.artistName ?? "",
            entry.track.title ?? "",
            entry.track.albumTitle ?? "",
            entry.track.genre ?? "",
            "\(entry.durationSeconds)",
            "\(entry.totalListens)",
            clusters,
        ].joined(separator: fieldSeparator)
    }

    /// Affinity descending, then committed passes descending, then the total
    /// tie-break ascending — whose first component is the identity key.
    static func ranked(_ candidates: [RankedReplay]) -> [ReplayHeatDigest] {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.entry.replayAffinity != rhs.entry.replayAffinity {
                return lhs.entry.replayAffinity > rhs.entry.replayAffinity
            }
            if lhs.entry.totalPasses != rhs.entry.totalPasses {
                return lhs.entry.totalPasses > rhs.entry.totalPasses
            }
            return lhs.tieBreak < rhs.tieBreak
        }
        return sorted.prefix(replayEntityLimit).map(\.entry)
    }
}
