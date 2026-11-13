// DownloadToastPolicyTests — what the download queue is allowed to say, and when.
//
// This policy is the only thing in the Downloads surface that makes a CLAIM. Every
// other failure mode is loud and honest (a row goes red, a badge stops moving); a
// wrong completion toast instead tells the listener something that is not true —
// "1 download finished" straight after they pressed Cancel All.
//
// The whole subject is ORDER. `DownloadQueueService`'s driver settles a finished row
// by publishing the row's terminal state through `onItemProgress` FIRST and the queue
// snapshot SECOND, and it publishes nothing at all afterwards — the pump's `while`
// simply exits. So a completion counted anywhere later than `onItemProgress` is
// counted after the drain has already been assessed and zeroed, which is exactly the
// off-by-one this suite pins shut. ``replayDrain(_:outcomes:)`` reproduces that order
// rather than a convenient one.
//
// ── AND THE UNIT OF EVERY CLAIM IS A DRAIN, NOT A ROW ────────────────────────
//
// Several transfers run at once, so the single-row ``replayDrain(_:outcomes:)`` cannot
// express the shapes that actually reach these policies: three rows settling against one
// another, a failure landing between two successes, three rows failing on the same broken
// folder within a millisecond. ``ParallelDrainReplay`` covers those.
//
// It replays rather than driving `FakeDownloadQueue`, and NOT by preference: linking
// `PlayerCoreTestSupport` into `macampMacTests` makes Tuist narrow that product's
// supported platforms to macOS, which fails the lint for twelve PlayerCore test targets
// that declare iOS. The shipped double is therefore unreachable from this target, so the
// order it publishes in is pinned where it IS reachable — `DownloadQueueSeamTests`
// (`PlayerCore/Tests/DownloadsTests`) asserts terminal-state-before-snapshot at N > 1 —
// and this replay restates that one contract.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Download toast policy")
@MainActor
struct DownloadToastPolicyTests {
    @Test("a single-item drain announces one finished download")
    func singleItemDrainAnnouncesOne() {
        let toast = ToastManager()
        let policy = DownloadToastPolicy(toast: toast)

        replayDrain(policy, outcomes: [.finished(fileURL: landedFile)])

        #expect(toast.activeToast?.text == MacAMPStrings.downloadsFinishedToast(1))
    }

    /// The count is the drain's whole content, so a drain that lands three files must
    /// say three. Counting anywhere after the empty snapshot loses the LAST row every
    /// time, which reads as a plausible "2" and hides itself.
    @Test("a three-item drain announces three")
    func threeItemDrainAnnouncesThree() {
        let toast = ToastManager()
        let policy = DownloadToastPolicy(toast: toast)

        replayDrain(policy, outcomes: Array(repeating: .finished(fileURL: landedFile), count: 3))

        #expect(toast.activeToast?.text == MacAMPStrings.downloadsFinishedToast(3))
    }

    /// The reported defect, stated directly: a queue emptied by Cancel All has nothing
    /// to celebrate, and must not inherit the previous drain's leftover count and
    /// announce it as this drain's work.
    @Test("a Cancel All drain after a successful one says nothing new")
    func cancelAllAfterASuccessfulDrainSaysNothingNew() {
        let toast = ToastManager()
        let policy = DownloadToastPolicy(toast: toast)

        replayDrain(policy, outcomes: Array(repeating: .finished(fileURL: landedFile), count: 3))
        let afterSuccess = toast.activeToast
        replayDrain(policy, outcomes: [.cancelled, .cancelled])

        #expect(afterSuccess?.text == MacAMPStrings.downloadsFinishedToast(3))
        #expect(toast.activeToast == afterSuccess)
    }

    /// A drain whose every row failed produces the failure sentence and nothing else.
    /// The completion toast would be a second, contradictory claim about the same work.
    @Test("an all-failed drain raises no completion toast")
    func allFailedDrainRaisesNoCompletionToast() {
        let toast = ToastManager()
        let policy = DownloadToastPolicy(toast: toast)

        replayDrain(policy, outcomes: Array(repeating: .failed(transferFault), count: 2))

        #expect(toast.activeToast?.text == transferFaultMessage)
    }

    /// The counter is per-drain, and the only way to observe that is a drain that
    /// finished NOTHING: any drain that did finish work masks a stale leftover by
    /// cancelling it out one-for-one.
    @Test("a drain that finished nothing inherits no count from the drain before")
    func aBarrenDrainInheritsNoCount() {
        let toast = ToastManager()
        let policy = DownloadToastPolicy(toast: toast)

        replayDrain(policy, outcomes: Array(repeating: .finished(fileURL: landedFile), count: 3))
        replayDrain(policy, outcomes: Array(repeating: .failed(transferFault), count: 2))

        #expect(toast.activeToast?.text == transferFaultMessage)
    }

    /// Fifty rows pointed at one broken folder must raise one bubble, not fifty — and
    /// the next drain must still get its own sentence.
    @Test("the first failure of a drain is announced once, and the latch re-arms")
    func firstFailureIsAnnouncedOncePerDrain() {
        let toast = ToastManager()
        let policy = DownloadToastPolicy(toast: toast)

        replayDrain(policy, outcomes: [.failed(transferFault), .failed(engineFault)])
        #expect(toast.activeToast?.text == transferFaultMessage)

        replayDrain(policy, outcomes: [.failed(engineFault)])
        #expect(toast.activeToast?.text == engineFaultMessage)
    }

    /// `.destinationUnavailable` belongs to `AppEnvironment+Downloads.handleDownloadState`,
    /// which says something this policy cannot — it names the System Settings pane AND
    /// opens it. Skipping it WITHOUT consuming the latch is the point: a later,
    /// different fault in the same drain is still worth its one sentence.
    @Test("an unwritable destination does not consume the failure latch")
    func destinationUnavailableLeavesTheLatchArmed() {
        let alone = ToastManager()
        replayDrain(DownloadToastPolicy(toast: alone), outcomes: [.failed(.destinationUnavailable)])
        #expect(alone.activeToast == nil)

        let toast = ToastManager()
        let policy = DownloadToastPolicy(toast: toast)

        replayDrain(policy, outcomes: [.failed(.destinationUnavailable), .failed(transferFault)])

        #expect(toast.activeToast?.text == transferFaultMessage)
    }

    /// Stopping a download is an instruction, not a fault. Neither the bare
    /// `.cancelled` state nor a cancellation that arrives wearing `.failed` may be
    /// reported back to the person who asked for it.
    @Test("a cancellation is never announced as a failure")
    func cancellationIsNeverAnnouncedAsAFailure() {
        let toast = ToastManager()
        let policy = DownloadToastPolicy(toast: toast)

        replayDrain(policy, outcomes: [.cancelled, .failed(.cancelled), .failed(.cancelledByEngine)])

        #expect(toast.activeToast == nil)
    }

    /// The import toast's own gate, and the reason `DownloadImportAnnouncement` is a
    /// named function rather than a chained `guard`: with auto-import off the importer
    /// answers `nil`, and `nil` must never be read as a successful import. The empty
    /// summary is the third case that keeps the two apart — there a scan DID run and
    /// found nothing new, which is equally nothing to announce.
    @Test("the import toast follows the importer's decision, and nil is not an import")
    func importToastFollowsTheImporterDecision() {
        #expect(DownloadImportAnnouncement.announces(nil) == false)
        #expect(DownloadImportAnnouncement.announces(ScanSummary(added: 1)))
        #expect(DownloadImportAnnouncement.announces(ScanSummary()) == false)
    }

    // MARK: Parallel drains

    /// Three transfers running at once settle against one another, and the drain they
    /// share must still speak once and count all three. The interleaved progress
    /// samples are the point: they make the run a real overlap rather than three
    /// completions in a burst, and a policy that counted per row would answer "1", "2",
    /// "3" here instead of one sentence.
    @Test("three parallel finishes announce one toast naming all three")
    func threeParallelFinishesAnnounceOneToastOfThree() {
        let drain = ParallelDrainReplay()
        let ids = drain.enqueue(3)
        drain.startAll()

        drain.progress(ids[1])
        drain.settle(ids[0], state: .finished(fileURL: landedFile))
        drain.progress(ids[2])
        drain.settle(ids[1], state: .finished(fileURL: landedFile))
        drain.settle(ids[2], state: .finished(fileURL: landedFile))

        #expect(drain.toasts == [MacAMPStrings.downloadsFinishedToast(3)])
    }

    /// A failure inside a drain is announced on its own terms and must not enter the
    /// completion count. Both halves are asserted in one sequence because the failure
    /// arriving BETWEEN two successes is the ordering that can corrupt the count.
    @Test("an interleaved failure is announced once and excluded from the drain count")
    func anInterleavedFailureIsExcludedFromTheCount() {
        let drain = ParallelDrainReplay()
        let ids = drain.enqueue(4)
        drain.start()
        drain.start()
        drain.start()

        drain.settle(ids[0], state: .finished(fileURL: landedFile))
        drain.start()
        drain.settle(ids[1], state: .failed(transferFault))
        drain.settle(ids[2], state: .finished(fileURL: landedFile))
        drain.settle(ids[3], state: .finished(fileURL: landedFile))

        #expect(drain.toasts == [transferFaultMessage, MacAMPStrings.downloadsFinishedToast(3)])
    }

    /// The reported hazard: three rows racing to report the same unwritable folder.
    /// One fault, one fix, one interruption.
    ///
    /// The second drain is the half a per-row latch could never satisfy. It finishes
    /// NOTHING, so the reset this latch used to hang off — `onItemFinished` — never
    /// fires, and the offer would be suppressed forever on a folder that is still
    /// broken. Re-arming on the drain edge is what lets the second paste speak.
    @Test("racing unwritable destinations offer recovery once per drain")
    func racingUnwritableDestinationsOfferRecoveryOncePerDrain() {
        let drain = ParallelDrainReplay()
        let first = drain.enqueue(3)
        drain.startAll()
        for id in first {
            drain.settle(id, state: .failed(.destinationUnavailable))
        }
        #expect(drain.recoveryOffers == 1)

        let second = drain.enqueue(2)
        drain.startAll()
        for id in second {
            drain.settle(id, state: .failed(.destinationUnavailable))
        }
        #expect(drain.recoveryOffers == 2)
        #expect(drain.toasts.isEmpty)
    }
}

// MARK: - Replay

/// A file path standing in for the one the engine moved into the destination. Its
/// value is never read — the policy counts the CASE, not the URL.
@MainActor private let landedFile = URL(fileURLWithPath: "/tmp/macamp-download.m4a")

/// A real fault, and a second DIFFERENT real fault, so a suppressed sentence is
/// distinguishable from a shown one. Their messages differ (`errorDownloadFailed` vs
/// `errorUnknown`), which is what makes the latch assertions meaningful.
@MainActor private let transferFault = DownloadError.downloadFailed(detail: nil)
@MainActor private let engineFault = DownloadError.unknown(code: 7)
@MainActor private let transferFaultMessage = String(localized: transferFault.message)
@MainActor private let engineFaultMessage = String(localized: engineFault.message)

/// Replays one whole drain in the queue's own publication order.
///
/// Per row the driver does three things in this sequence: it picks the row up and
/// publishes a snapshot (`current` set), it settles the row by publishing the terminal
/// state, and only THEN it publishes the post-settle snapshot. The last row's settle is
/// therefore where the queue becomes empty — and the terminal state has already been
/// published by the time it does.
///
/// Rows that a Cancel All dropped while still pending reach the policy in this same
/// shape (a `.cancelled` state, then a snapshot); the policy reads membership and
/// states, never how a row left the queue, so one replay covers both endings.
@MainActor
private func replayDrain(_ policy: DownloadToastPolicy, outcomes: [DownloadState]) {
    publishQueue(policy, pending: outcomes.count, hasCurrent: false)
    for (index, outcome) in outcomes.enumerated() {
        let remaining = outcomes.count - index - 1
        publishQueue(policy, pending: remaining, hasCurrent: true)
        policy.noteState(outcome)
        publishQueue(policy, pending: remaining, hasCurrent: false)
    }
}

/// Publishes the snapshot a queue holding `pending` waiting rows emits, with or without
/// a row in flight.
@MainActor
private func publishQueue(_ policy: DownloadToastPolicy, pending: Int, hasCurrent: Bool) {
    policy.noteQueue(DownloadQueueSnapshot(
        activeItems: hasCurrent ? [queuedRow(0)] : [],
        pendingItems: (0 ..< pending).map(queuedRow),
        isPaused: false
    ))
}

/// A queue row. Only its presence matters here — the policy reads the snapshot's
/// emptiness, never a row's fields.
private func queuedRow(_ index: Int) -> DownloadItem {
    DownloadItem(
        canonicalVideoID: "videoID\(index)",
        sourceURL: URL(fileURLWithPath: "/tmp/macamp-source-\(index)")
    )
}

// MARK: - Parallel replay

/// Replays a drain that holds SEVERAL rows in flight at once, in the driver's order.
///
/// Every step mirrors one thing `DownloadQueueService` does:
///
///   * ``enqueue(_:)`` — `append(_:)`: rows join `pending`, then one snapshot.
///   * ``start()`` — `pump()`: one row moves `pending` → `active`, its first state is
///     published, then the snapshot.
///   * ``progress(_:)`` — `publishProgress(_:for:)`: a row state and NO snapshot, which
///     is the only thing that makes an overlap observable at all.
///   * ``settle(_:state:)`` — `settle(_:)`: `active.removeAll` → `emitItemState` →
///     `emitQueueChanged`, in that order, so a terminal state is always published while
///     the queue still reads non-empty and the empty snapshot arrives after it.
///
/// Both policies are driven in the composition root's own chain order:
/// `connectDownloads(settings:)` runs `wireDownloadSeams` first and `connectDownloadsUI`
/// second, and every assignment calls the handler it found, so the recovery policy sees
/// each event before the toast policy does. The single substitution is
/// `handleDownloadState(_:recovery:)`, replaced by the
/// ``DownloadRecoveryPolicy/shouldOffer(for:)`` it wraps — the method itself would open
/// System Settings on whatever machine runs the suite.
@MainActor
private final class ParallelDrainReplay {
    private let toast = ToastManager()
    private let policy: DownloadToastPolicy
    private let recovery = DownloadRecoveryPolicy()
    private var active: [DownloadItem] = []
    private var pending: [DownloadItem] = []
    private var minted = 0

    /// How many times a drain was interrupted to offer the System Settings recovery.
    private(set) var recoveryOffers = 0
    /// Every toast the run raised, in order. Sampled after each policy call rather than
    /// read once at the end, so a sentence overwritten moments later still counts.
    private(set) var toasts: [String] = []

    init() {
        policy = DownloadToastPolicy(toast: toast)
    }

    @discardableResult
    func enqueue(_ count: Int) -> [UUID] {
        let rows = (0 ..< count).map { offset in queuedRow(minted + offset) }
        minted += count
        pending.append(contentsOf: rows)
        publishSnapshot()
        return rows.map(\.id)
    }

    func start() {
        guard !pending.isEmpty else { return }
        active.append(pending.removeFirst())
        publish(.fetchingMetadata)
        publishSnapshot()
    }

    func startAll() {
        while !pending.isEmpty {
            start()
        }
    }

    func progress(_ id: UUID) {
        guard active.contains(where: { $0.id == id }) else { return }
        publish(.downloading(fraction: 0.5, speedBytesPerSec: 2048, etaSeconds: 4))
    }

    func settle(_ id: UUID, state: DownloadState) {
        guard active.contains(where: { $0.id == id }) else { return }
        active.removeAll { $0.id == id }
        publish(state)
        publishSnapshot()
    }

    private func publish(_ state: DownloadState) {
        if recovery.shouldOffer(for: state) {
            recoveryOffers += 1
        }
        policy.noteState(state)
        captureToast()
    }

    private func publishSnapshot() {
        let snapshot = DownloadQueueSnapshot(activeItems: active, pendingItems: pending, isPaused: false)
        recovery.noteQueue(snapshot)
        policy.noteQueue(snapshot)
        captureToast()
    }

    private func captureToast() {
        guard let text = toast.activeToast?.text, text != toasts.last else { return }
        toasts.append(text)
    }
}
