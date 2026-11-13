// DownloadTeardownWiringTests — Quit stops the downloader.
//
// A `Process` this app spawned does NOT die with it. On macOS an orphaned child is
// reparented to launchd and keeps running: still writing into the staging directory,
// still using the network, with no window and no way for the listener to stop it short
// of Activity Monitor. The only moment MacAMP can prevent that is while it is still
// alive, which is why `makeTerminationFlush` cancels the queue.
//
// That makes this a wiring test, deliberately: the flush is a closure assembled in one
// place and handed to the app delegate in another, and the failure mode is that the
// call is simply absent — which no amount of queue-level testing would catch.
// `TerminationFlushTests` covers the delegate half (the `terminateLater` race and its
// timeout); this covers what the closure does.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Download teardown wiring")
@MainActor
struct DownloadTeardownWiringTests {
    @Test("the quit flush cancels the download queue")
    func quittingCancelsEveryDownload() async {
        let environment = AppEnvironment.preview()
        let queue = TeardownRecordingQueue()
        environment.downloads = queue

        await AppEnvironment.makeTerminationFlush(environment)()

        #expect(queue.cancelAllCount == 1)
    }

    /// The composition root assigns the queue AFTER the splash, so a Quit during
    /// launch finds `downloads` still `nil`. That path must be a no-op, not a crash —
    /// the same reason `MenuPruningDelegate` answers `.terminateNow` when no flush is
    /// installed at all.
    @Test("a quit before the queue exists is a no-op")
    func quittingDuringLaunchIsSafe() async {
        let environment = AppEnvironment.preview()

        await AppEnvironment.makeTerminationFlush(environment)()

        #expect(environment.downloads == nil)
    }

    /// The whole queue goes, not just the item in flight. `cancelCurrent()` would look
    /// right — the visible download stops — while every pending row it advanced to
    /// spawns a fresh child on the way out.
    @Test("quitting cancels the whole queue, not merely the item in flight")
    func quittingClearsPendingWorkToo() async {
        let environment = AppEnvironment.preview()
        let queue = TeardownRecordingQueue()
        environment.downloads = queue

        await AppEnvironment.makeTerminationFlush(environment)()

        #expect(queue.cancelAllCount == 1)
        #expect(queue.cancelCurrentCount == 0)
    }
}

/// Counts what the quit path asked of the queue. A hand-written double rather than
/// `FakeDownloadQueue`, because `macampMacTests` does not depend on
/// `PlayerCoreTestSupport` and adding that dependency to run one counter would mean
/// regenerating the Xcode project.
@MainActor
final class TeardownRecordingQueue: DownloadQueueing {
    private(set) var cancelAllCount = 0
    private(set) var cancelCurrentCount = 0
    private(set) var cancelledItemIDs: [UUID] = []
    var onQueueChanged: (@Sendable (DownloadQueueSnapshot) -> Void)?
    var onItemProgress: (@Sendable (UUID, DownloadState) -> Void)?

    func enqueue(urls _: [URL]) async -> EnqueueOutcome {
        .zero
    }

    func confirmPlaylist(_: UUID) async -> EnqueueOutcome {
        .zero
    }

    func cancelCurrent() {
        cancelCurrentCount += 1
    }

    func cancel(itemID: UUID) {
        cancelledItemIDs.append(itemID)
    }

    func removePending(_: UUID) {}
    func movePending(_: UUID, to _: Int) {}
    func pause() {}
    func resume() {}
    func cancelAll() {
        cancelAllCount += 1
    }
}
