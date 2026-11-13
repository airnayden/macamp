// ReplayGainTagWritePlan — what a "Write ReplayGain Tags…" action would do, decided
// BEFORE anything is written.
//
// The partition is pure and happens up front for one reason: the confirmation the
// listener sees has to name a real file count and a real refusal breakdown. A sheet
// that said "write tags to 40 files" and then silently refused 12 of them would be
// a lie the listener has no way to detect — ``ReplayGainTagSupport`` refuses from the
// path extension alone, before a file is ever opened, so there is no excuse for
// deciding late.
//
// The refusal taxonomy is ``ReplayGainTagUnsupportedReason``'s, in full. "Opus" is
// the case people name, but the allow-list is `["mp3", "flac"]` and everything else
// falls into one of three buckets — the Ogg family (which may normalise against
// R128's −23 LUFS rather than RG 2.0's −18), the MP4 family (whose tags the pinned
// TagLib silently discards), and everything unverified. Collapsing those into one
// "skipped" number would tell an M4A owner nothing.
import Foundation
import Metadata

/// One track a write action was asked about.
public struct ReplayGainTagTarget: Sendable, Equatable, Hashable {
    /// The library row the measured values are read from.
    public let trackId: Int64
    /// The audio file the tags would be written to.
    public let filePath: String

    public init(trackId: Int64, filePath: String) {
        self.trackId = trackId
        self.filePath = filePath
    }

    /// The file this target names.
    public var url: URL {
        URL(fileURLWithPath: filePath)
    }
}

/// How many targets one refusal reason accounts for.
public struct ReplayGainTagSkip: Sendable, Equatable, Hashable {
    public let reason: ReplayGainTagUnsupportedReason
    public let count: Int

    public init(reason: ReplayGainTagUnsupportedReason, count: Int) {
        self.reason = reason
        self.count = count
    }
}

/// The eligible/refused split of a selection, and the gate on confirming it.
public struct ReplayGainTagWritePlan: Sendable, Equatable {
    /// Targets whose format can carry RG 2.0 tags.
    public let eligible: [ReplayGainTagTarget]

    /// Refused targets, grouped by reason. Empty reasons are absent, and the
    /// order is ``ReplayGainTagUnsupportedReason``'s own `allCases` order so the
    /// sheet's breakdown never reshuffles between presentations.
    public let skipped: [ReplayGainTagSkip]

    public init(eligible: [ReplayGainTagTarget], skipped: [ReplayGainTagSkip]) {
        self.eligible = eligible
        self.skipped = skipped
    }

    public var eligibleCount: Int {
        eligible.count
    }

    public var skippedCount: Int {
        skipped.reduce(0) { $0 + $1.count }
    }

    /// Whether the confirm action may be offered at all.
    ///
    /// A plan with nothing eligible has no write to confirm, so the sheet's
    /// primary button is disabled rather than firing a no-op the listener would
    /// read as success. ``ReplayGainTagWriteModel/write(_:)`` re-checks it, so a
    /// keyboard route cannot get past the disabled control either.
    public var canConfirm: Bool {
        !eligible.isEmpty
    }

    /// Partitions `targets` by what their format can actually carry.
    ///
    /// De-duplicates by `trackId`, keeping the order the listener sees: a table
    /// selection is a `Set`, which iterates nondeterministically, and a plan that
    /// listed the same file twice would write it twice.
    public static func make(for targets: [ReplayGainTagTarget]) -> ReplayGainTagWritePlan {
        var seen = Set<Int64>()
        var eligible: [ReplayGainTagTarget] = []
        var counts: [ReplayGainTagUnsupportedReason: Int] = [:]
        for target in targets where seen.insert(target.trackId).inserted {
            if let reason = ReplayGainTagSupport.unsupportedReason(for: target.url) {
                counts[reason, default: 0] += 1
            } else {
                eligible.append(target)
            }
        }
        let skipped = ReplayGainTagUnsupportedReason.allCases.compactMap { reason in
            counts[reason].map { ReplayGainTagSkip(reason: reason, count: $0) }
        }
        return ReplayGainTagWritePlan(eligible: eligible, skipped: skipped)
    }
}
