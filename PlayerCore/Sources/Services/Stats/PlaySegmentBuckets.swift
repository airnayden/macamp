// PlaySegmentBuckets — the pure maths behind a replay heatmap.
//
// Separated from `PlaySegmentTracker` so the part that is easy to get subtly wrong
// (half-open bucket edges, the sub-second artifact filter) is a free function over
// values, drivable from a test with no timer, no coordinator and no database.
//
// This file imports only Foundation + Persistence; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import Foundation
import Persistence

/// One reading of the playhead: where it was, and whether sound was coming out.
///
/// The tracker's whole input contract. A 1 Hz timer produces these in production;
/// a test produces them by hand.
public struct PlayheadSample: Sendable, Equatable {
    /// Playhead position in seconds from the start of the track.
    public var time: TimeInterval
    /// Whether the engine was playing when the position was read.
    public var isPlaying: Bool

    public init(time: TimeInterval, isPlaying: Bool) {
        self.time = time
        self.isPlaying = isPlaying
    }
}

/// A contiguous stretch of a track that was actually listened to, in seconds.
public struct PlaySegmentRange: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var length: TimeInterval {
        end - start
    }
}

/// Converts listened ranges into the 100 relative bucket increments a heatmap merges.
public enum PlaySegmentBuckets {
    /// Ranges shorter than this are dropped rather than counted.
    ///
    /// This is the gapless guard rail. Under gapless playback a 1 Hz tick can land in
    /// the async window *after* the successor has started but *before* the outgoing
    /// track's `.natural` signal arrives — opening a near-zero-length range at the
    /// successor's position while the tracker still holds the finished track. Dropping
    /// sub-half-second ranges makes that artifact structurally impossible. The cost is
    /// a documented, accepted loss of genuine sub-second listens, which carry no
    /// meaning in a 100-bucket heatmap anyway.
    public static let minimumCommittedLength: TimeInterval = 0.5

    /// The per-bucket increments for `ranges`, against a track of `duration` seconds.
    ///
    /// Buckets are **half-open**: bucket `i` covers `[i%, (i+1)%)` of the duration, so
    /// a listen that stops exactly at 40% increments buckets 0…39 and leaves bucket 40
    /// untouched. Each qualifying range contributes at most one increment per bucket;
    /// two ranges overlapping the same bucket contribute two.
    ///
    /// Returns an all-zero array for a non-positive duration — an unknown-length
    /// source has no relative position to speak of.
    public static func deltas(for ranges: [PlaySegmentRange], duration: TimeInterval) -> [UInt32] {
        var deltas = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        guard duration > 0, duration.isFinite else { return deltas }
        for range in ranges {
            guard let span = bucketSpan(for: range, duration: duration) else { continue }
            for index in span where deltas[index] < UInt32.max {
                deltas[index] += 1
            }
        }
        return deltas
    }

    /// The inclusive bucket index range a listen covers, or `nil` when it is too
    /// short (or degenerate) to count.
    private static func bucketSpan(
        for range: PlaySegmentRange,
        duration: TimeInterval
    ) -> ClosedRange<Int>? {
        guard range.start.isFinite, range.end.isFinite else { return nil }
        let lastIndex = PlaySegmentHeatRecord.bucketCount - 1
        let scale = Double(PlaySegmentHeatRecord.bucketCount)
        let start = min(max(0, range.start), duration)
        let end = min(max(start, range.end), duration)
        guard end - start >= minimumCommittedLength else { return nil }
        let first = min(max(0, Int(scale * start / duration)), lastIndex)
        let last = min(max(first, Int((scale * end / duration).rounded(.up)) - 1), lastIndex)
        return first ... last
    }
}
