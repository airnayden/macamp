// ReplayGainTagWriteModel — the ONLY path that writes ReplayGain tags to a file.
//
// It takes a ``ReplayGainTagWritePlan`` — never a raw selection — so a write is
// structurally impossible without the partition the confirmation sheet showed. The
// plan is re-checked here as well as in the sheet, because a disabled button is a
// UI fact and this is the invariant.
//
// The DB → tag conversion lives here rather than in `Metadata`, which must never
// import `Persistence`. Four fields, one table each way:
//
//   trackGainDB ← ReplayGainSynthesis.gainDB(forIntegratedLUFS: integratedLUFS)
//   trackPeak   ← truePeak   (verbatim — already linear)
//   albumGainDB ← ReplayGainSynthesis.gainDB(forIntegratedLUFS: albumLUFS)
//   albumPeak   ← albumPeak  (verbatim)
//
// `ReplayGainSynthesis` is the single definition of the −18 LUFS reference; never
// re-derive it here. Its silence sentinel propagates all the way: `gainDB(nil)` and
// `gainDB(-.infinity)` are `nil`, and a `nil` gain field leaves that tag exactly as
// it was rather than claiming the file is already at reference.
import Foundation
import Metadata
import Persistence
import Services

/// What one confirmed write actually did.
public struct ReplayGainTagWriteOutcome: Sendable, Equatable {
    /// Files whose tags were rewritten.
    public let written: Int

    /// Eligible files that carried nothing true to write — never measured, or
    /// measured as silence with no peak worth recording. Counted apart from a
    /// failure: nothing went wrong, there was simply no value to state.
    public let unmeasured: Int

    /// Files the writer refused or could not rewrite.
    public let failed: Int

    public init(written: Int, unmeasured: Int, failed: Int) {
        self.written = written
        self.unmeasured = unmeasured
        self.failed = failed
    }

    /// The terminal state of a plan that could not be confirmed.
    ///
    /// `nothing`, NOT `none`: this type is routinely held as an Optional and a
    /// static named `none` would silently resolve to `Optional.none` at every
    /// call site — the reason ``ReplayGainSource`` spells its own case
    /// `unavailable`.
    public static let nothing = ReplayGainTagWriteOutcome(written: 0, unmeasured: 0, failed: 0)
}

/// Writes measured loudness into a selection's ReplayGain tags, on confirmation.
@MainActor
public final class ReplayGainTagWriteModel {
    private let loudness: any TrackLoudnessReading
    private let writer: any ReplayGainTagWriting

    /// - Parameters:
    ///   - loudness: The cached-loudness read seam. One row per eligible file.
    ///   - writer: The atomic tag writer. Injected so a suite can drive the whole
    ///     action without touching a real audio file.
    public init(
        loudness: any TrackLoudnessReading,
        writer: any ReplayGainTagWriting = ReplayGainTagWriter()
    ) {
        self.loudness = loudness
        self.writer = writer
    }

    /// The eligible/refused split the confirmation sheet presents.
    ///
    /// Pure, synchronous and side-effect-free: it opens no file and reads no row.
    public nonisolated func plan(for targets: [ReplayGainTagTarget]) -> ReplayGainTagWritePlan {
        ReplayGainTagWritePlan.make(for: targets)
    }

    /// Writes `plan`'s eligible files. **Call only from a confirmed action.**
    ///
    /// Refused formats never reach the writer — they were partitioned out before
    /// the sheet was shown, and are not re-examined here.
    @discardableResult
    public func write(_ plan: ReplayGainTagWritePlan) async -> ReplayGainTagWriteOutcome {
        guard plan.canConfirm else { return .nothing }
        var written = 0
        var unmeasured = 0
        var failed = 0
        for target in plan.eligible {
            switch await outcome(for: target) {
            case .written: written += 1
            case .unmeasured: unmeasured += 1
            case .failed: failed += 1
            }
        }
        return ReplayGainTagWriteOutcome(written: written, unmeasured: unmeasured, failed: failed)
    }
}

// MARK: - One file

private extension ReplayGainTagWriteModel {
    enum TargetOutcome {
        case written
        case unmeasured
        case failed
    }

    func outcome(for target: ReplayGainTagTarget) async -> TargetOutcome {
        guard let record = try? await loudness.loudness(forTrackId: target.trackId) else {
            return .unmeasured
        }
        let values = Self.tagValues(from: record)
        guard !values.isEmpty else { return .unmeasured }
        return await commit(values, to: target.url) ? .written : .failed
    }

    /// Performs the atomic rewrite off the main actor.
    ///
    /// A tag write copies the file, patches the copy and renames it into place —
    /// disk work measured in the tens of milliseconds per file, which must not
    /// land on the actor drawing the sheet.
    func commit(_ values: ReplayGainTagValues, to url: URL) async -> Bool {
        let writer = writer
        return await Task.detached(priority: .userInitiated) {
            do {
                try writer.writeReplayGainTags(values, to: url)
                return true
            } catch {
                return false
            }
        }.value
    }

    static func tagValues(from record: TrackLoudnessRecord) -> ReplayGainTagValues {
        ReplayGainTagValues(
            trackGainDB: ReplayGainSynthesis.gainDB(forIntegratedLUFS: record.integratedLUFS),
            trackPeak: record.truePeak,
            albumGainDB: ReplayGainSynthesis.gainDB(forIntegratedLUFS: record.albumLUFS),
            albumPeak: record.albumPeak
        )
    }
}
