// DownloadsUIWiring — connects the download queue to the Downloads pane and to the
// toast layer.
//
// Two jobs, both wired onto the SAME seams `AppEnvironment+Downloads.swift` already
// uses, and both CHAINED: `DownloadQueueing` vends exactly one slot per seam, so every
// assignment here calls the handler it found first (the `wireDownloadSeams`
// precedent). A bare assignment on either side would silently drop the other's work —
// on this side, the snapshot box `DownloadToolManager` reads to refuse an engine
// update mid-download, and the System Settings recovery this file deliberately leaves
// to `handleDownloadState(_:recoveryOffered:)`.
//
// It wires TWO seams, not three. `onItemFinished` belongs entirely to
// `AppEnvironment+Downloads.swift`, where it drives the library import that turns a
// finished download into a track; this file has no business on it — see the counting
// note below.
//
// ── THE SEQUENCE IS STAMPED AT CAPTURE TIME ──────────────────────────────────
//
// `DownloadQueueStore.ingest(sequence:snapshot:)` takes the counter as a parameter
// because `DownloadQueueSnapshot` carries none. It is incremented synchronously inside
// the `@Sendable` closure, BEFORE anything else, because a hop is exactly what would
// let two snapshots arrive out of order. `MainActor.assumeIsolated` states the seams'
// own documented contract rather than dodging it, so today there is no hop at all —
// the lock-boxed counter is what keeps that true if the seam ever grows one.
//
// ── TOAST POLICY (plan Metis 19) ─────────────────────────────────────────────
//
// Exactly three toasts, and NO per-item completion toast: a fifty-link paste must not
// produce fifty bubbles.
//
//   1. queue-complete — once, when a drain that actually produced files empties.
//   2. first failure per drain — the ladder's own sentence, said once.
//   3. engine-update result — raised by the Downloads preference pane.
//
// ── WHY A COMPLETION IS COUNTED FROM `onItemProgress` ────────────────────────
//
// The queue-complete toast needs the drain's finished-file count settled BEFORE the
// empty snapshot is assessed, and exactly one seam is early enough. `settle` (in
// `DownloadQueueService+Driver.swift`) nils `current`, publishes the row's terminal
// state through `emitItemState`, and publishes the queue snapshot through
// `emitQueueChanged` on the very next line — so the LAST row's `.finished` arrives
// just before the snapshot that empties the queue. `onItemFinished` fires after both,
// and the driver's `while` then exits without publishing anything further: a count
// taken there lands after `noteQueue` has already read and zeroed the counter, so
// every drain would report one fewer file than it produced and carry the missing one
// into the NEXT drain — which is how a Cancel All comes to claim "1 download
// finished".
//
// This file constructs no `Process` and no `URLSession` — `macOS/Sources/Downloads` is
// scanned wholesale by `scripts/check-downloader-boundary.sh`.
import Foundation
import os
import Persistence
import Services
import ViewModels

extension AppEnvironment {
    /// Builds the Downloads pane's projection and connects it to the queue's seams.
    ///
    /// Called from `connectDownloads(settings:)` AFTER `wireDownloadSeams`, so the
    /// snapshot box and the System Settings recovery are the handlers this wiring
    /// chains onto.
    func connectDownloadsUI(_ queue: DownloadQueueService, oEmbed: any OEmbedFetching) {
        let store = DownloadQueueStore()
        // A SECOND repository over the same `database`, not the recorder's — a
        // `DownloadHistoryRepository` is a stateless value over one `DatabaseWriter`,
        // so sharing an instance would buy nothing and would give the paste hint a
        // reference to the object that WRITES history. This one only ever reads.
        downloadsModel = DownloadsViewModel(
            queue: queue,
            store: store,
            history: DownloadHistoryRepository(database)
        )
        downloadThumbnails = DownloadThumbnailStore(fetcher: oEmbed)
        let policy = DownloadToastPolicy(toast: toast)
        let sequence = OSAllocatedUnfairLock(initialState: 0)

        let previousSnapshotHandler = queue.onQueueChanged
        queue.onQueueChanged = { snapshot in
            previousSnapshotHandler?(snapshot)
            let stamped = sequence.withLock { value -> Int in
                value += 1
                return value
            }
            MainActor.assumeIsolated {
                store.ingest(sequence: stamped, snapshot: snapshot)
                policy.noteQueue(snapshot)
            }
        }

        let previousProgressHandler = queue.onItemProgress
        queue.onItemProgress = { id, state in
            previousProgressHandler?(id, state)
            MainActor.assumeIsolated {
                store.ingestProgress(id: id, state: state)
                policy.noteState(state)
            }
        }
    }

    /// Reports the outcome of a manual download-engine self-update.
    ///
    /// The third leg of the toast policy. It lives here — beside the other two — rather
    /// than inside the preference pane that raises it, so all three sentences are
    /// written in one place and none of them can be spelled with a bare literal.
    func showDownloadEngineUpdateToast(_ result: Result<String, Error>) {
        switch result {
        case let .success(version):
            toast.show(
                text: MacAMPStrings.downloadsEngineUpdatedToast(version),
                icon: "checkmark.circle.fill"
            )
        case let .failure(error):
            let message = (error as? DownloadError)?.message ?? MacAMPStrings.downloadsEngineUpdateFailedToast
            toast.show(text: String(localized: message), icon: "exclamationmark.triangle.fill")
        }
    }
}

/// Decides which download events deserve a toast, and how often.
///
/// A tiny object rather than fields on ``AppEnvironment``: the queue owns the closures
/// that own this, so its lifetime is the queue's, and the composition root does not
/// grow three more stored properties for state nothing else reads.
@MainActor
final class DownloadToastPolicy {
    private let toast: ToastManager
    /// Files that actually landed since the queue last became non-empty.
    private var finishedThisDrain = 0
    /// One-shot latch: the first real failure of a drain is announced, the rest are
    /// not. Fifty rows pointed at one broken folder must not raise fifty bubbles; each
    /// row still carries its own copy in the list.
    private var reportedFailure = false
    /// Whether the queue has held work since the last drain. Without it an empty
    /// snapshot published at launch would read as a drain that finished nothing.
    private var wasBusy = false

    init(toast: ToastManager) {
        self.toast = toast
    }

    /// Fires the queue-complete toast on the non-empty → empty transition, and only
    /// when that drain actually produced files: a queue emptied by Cancel All, or one
    /// whose every row failed, has nothing to celebrate.
    func noteQueue(_ snapshot: DownloadQueueSnapshot) {
        guard snapshot.isEmpty else {
            wasBusy = true
            return
        }
        guard wasBusy else { return }
        wasBusy = false
        let finished = finishedThisDrain
        finishedThisDrain = 0
        reportedFailure = false
        guard finished > 0 else { return }
        toast.show(text: MacAMPStrings.downloadsFinishedToast(finished), icon: "arrow.down.circle.fill")
    }

    /// Counts one finished file, and announces the first real failure of a drain.
    ///
    /// Both jobs sit on this seam because both must be settled before the queue
    /// snapshot for the same row arrives — see the counting note in the file header. A
    /// `.finished` is counted and never announced: a fifty-link paste must not produce
    /// fifty bubbles, so a drain speaks once, through ``noteQueue(_:)``.
    ///
    /// A cancellation is not a fault, so it is never announced.
    /// ``DownloadError/destinationUnavailable`` is skipped and left to
    /// `handleDownloadState(_:recoveryOffered:)`, which says something this policy
    /// cannot — it names the System Settings pane AND opens it. Skipping it without
    /// consuming the latch is deliberate: a later, DIFFERENT fault in the same drain is
    /// still worth one sentence.
    func noteState(_ state: DownloadState) {
        if case .finished = state {
            finishedThisDrain += 1
            return
        }
        guard case let .failed(error) = state, !error.isCancellation else { return }
        guard error != .destinationUnavailable, !reportedFailure else { return }
        reportedFailure = true
        toast.show(text: String(localized: error.message), icon: "exclamationmark.triangle.fill")
    }
}
