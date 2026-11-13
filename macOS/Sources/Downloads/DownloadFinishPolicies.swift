// DownloadFinishPolicies — the two decisions a finished-or-failed download raises, held
// apart from the wiring that consults them.
//
// Moved VERBATIM out of `AppEnvironment+Downloads.swift` (a pure relocation, no code
// change) so that file keeps headroom under the SwiftLint `file_length` ceiling after
// `wireDownloadSeams` gained its chat routing parameter. Both types keep their names,
// their access level and their tests (`DownloadToastPolicyTests` in `macampMacTests`).
//
// They belong together: one decides when an unwritable destination is worth
// interrupting the listener for, the other whether a finished download earned the
// "added to your library" sentence. Both are consulted from the same seam, neither
// performs I/O, and neither constructs a `Process` or a `URLSession`.
import Foundation
import Services

// MARK: - Recovery policy

/// Decides when an unwritable destination is worth interrupting the listener for.
///
/// One offer per DRAIN — the span from the queue first holding work to the moment it
/// holds none again. Several transfers run in parallel against the same folder, so one
/// broken folder produces several `.destinationUnavailable` rows within milliseconds;
/// every one of them is the same fault with the same fix, and opening System Settings
/// once per row would be an assault. Each row still carries its own copy in the list.
///
/// The latch RE-ARMS on the drain edge, which is the half a per-row reset cannot
/// express. It was previously cleared by `onItemFinished`, and that is wrong in both
/// directions once more than one row can be in flight:
///
///   * a drain that finished NOTHING never re-armed it, so a second paste at the same
///     broken folder was met with silence — exactly when the offer is most wanted;
///   * a drain that DID finish something re-armed it mid-drain, so a volume that
///     dropped out again after one success could open System Settings a second and a
///     third time inside one drain.
///
/// `onItemFinished` is also published AFTER `settle` has already emitted the drain's
/// empty snapshot (`applyOutcome`, `DownloadQueueService+Driver.swift`), so on a drain's
/// last row that reset landed on the far side of the boundary it was meant to mark.
///
/// The drain edge is deliberately its own copy of `DownloadToastPolicy`'s rather than a
/// reading of that object: the two decide different things (one says a sentence, the
/// other opens a system pane), they live in different files for the boundary-scan reason
/// `DownloadsUIWiring.swift` documents, and that policy's failure latch is consumed by a
/// DIFFERENT fault — it skips `.destinationUnavailable` precisely so this one may speak.
@MainActor
final class DownloadRecoveryPolicy {
    private var offered = false
    /// Whether the queue has held work since the last drain, so an empty snapshot
    /// published at launch is not read as a drain that just ended.
    private var wasBusy = false

    /// Re-arms on the non-empty → empty edge, where one drain ends and the next begins.
    func noteQueue(_ snapshot: DownloadQueueSnapshot) {
        guard snapshot.isEmpty else {
            wasBusy = true
            return
        }
        guard wasBusy else { return }
        wasBusy = false
        offered = false
    }

    /// Whether `state` is an unwritable destination this drain has not reported yet,
    /// consuming the latch when it answers `true`.
    func shouldOffer(for state: DownloadState) -> Bool {
        guard case .failed(.destinationUnavailable) = state, !offered else { return false }
        offered = true
        return true
    }
}

// MARK: - Toast policy

/// Whether a finished download earned the "added to your library" toast.
///
/// A named function rather than a chained `guard` inside the seam so the invariant
/// "auto-import off ⇒ no import toast" is pinned directly by
/// `DownloadToastPolicyTests.importToastFollowsTheImporterDecision` in `macampMacTests`,
/// instead of being a condition whose removal would surface only as a toast announcing
/// an import that never happened.
enum DownloadImportAnnouncement {
    /// - Parameter decision: what ``DownloadLibraryImporter`` answered — `nil` when
    ///   auto-import is off and no scan ran, otherwise that scan's tally.
    static func announces(_ decision: ScanSummary?) -> Bool {
        guard let decision else { return false }
        return decision.added > 0 || decision.updated > 0
    }
}
