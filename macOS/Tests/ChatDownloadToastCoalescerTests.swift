// ChatDownloadToastCoalescerTests — one sentence per playlist, one guidance per batch.
//
// The window is INJECTED (one millisecond here, two seconds in production) and the
// suite awaits `waitForPendingWindow()` rather than sleeping: a test that slept for the
// real window would be both slow and a race, and the property under test is the
// COALESCING, not the duration.
//
// The emitter is injected too, so "one toast" is countable. `ToastManager` keeps only
// `activeToast`, which cannot tell one sentence from three — and three sentences that
// overwrote one another is exactly the defect this type exists to prevent.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Chat download toast coalescer")
@MainActor
struct ChatDownloadToastCoalescerTests {
    @Test("three appends to the same playlist produce ONE summary naming three tracks")
    func threeAppendsProduceOneSummary() async {
        let log = ToastLog()
        let coalescer = Self.make(log: log, names: [7: "Late Night"])

        for trackId in Int64(1) ... 3 {
            coalescer.record(.appended(playlistId: 7, trackId: trackId))
        }
        await coalescer.waitForPendingWindow()

        #expect(log.texts.count == 1)
        #expect(log.texts.first == MacAMPStrings.chatDownloadAddedToast(3, playlist: "Late Night"))
    }

    @Test("two playlists in one window get one sentence each")
    func twoPlaylistsGetOneSentenceEach() async {
        let log = ToastLog()
        let coalescer = Self.make(log: log, names: [1: "A", 2: "B"])

        coalescer.record(.appended(playlistId: 1, trackId: 10))
        coalescer.record(.appended(playlistId: 2, trackId: 11))
        coalescer.record(.appended(playlistId: 1, trackId: 12))
        await coalescer.waitForPendingWindow()

        #expect(log.texts.count == 2)
        #expect(log.texts.contains(MacAMPStrings.chatDownloadAddedToast(2, playlist: "A")))
        #expect(log.texts.contains(MacAMPStrings.chatDownloadAddedToast(1, playlist: "B")))
    }

    /// A playlist whose name could not be read must not produce `Added 3 tracks to ""`.
    @Test("an unreadable playlist name falls back to the unnamed sentence")
    func anUnreadableNameFallsBack() async {
        let log = ToastLog()
        let coalescer = Self.make(log: log, names: [:])

        coalescer.record(.appended(playlistId: 9, trackId: 1))
        await coalescer.waitForPendingWindow()

        #expect(log.texts == [MacAMPStrings.chatDownloadAddedUnnamedToast(1)])
    }

    /// The gate trips identically for every file in a batch — same switch, same folder,
    /// same fix — so the guidance is latched for the window.
    @Test("a batch that trips the gate four times says it once")
    func theGuidanceIsLatchedPerWindow() async {
        let log = ToastLog()
        let coalescer = Self.make(log: log, names: [:])

        for _ in 0 ..< 4 {
            coalescer.record(.gateFailed)
        }
        await coalescer.waitForPendingWindow()

        #expect(log.texts == [String(localized: MacAMPStrings.chatDownloadGateGuidanceToast)])
    }

    /// …and re-arms with it, or a second batch an hour later would be met with silence.
    @Test("the guidance latch re-arms on the next window")
    func theGuidanceLatchReArms() async {
        let log = ToastLog()
        let coalescer = Self.make(log: log, names: [:])

        coalescer.record(.gateFailed)
        await coalescer.waitForPendingWindow()
        coalescer.record(.gateFailed)
        await coalescer.waitForPendingWindow()

        #expect(log.texts.count == 2)
    }

    /// Faults are NOT latched and NOT buffered: each names a different track's failure.
    @Test("faults are said immediately, one sentence each")
    func faultsAreSaidImmediately() {
        let log = ToastLog()
        let coalescer = Self.make(log: log, names: [:])

        coalescer.record(.appendAbandoned)
        coalescer.record(.playlistMissing(4))

        #expect(log.texts.count == 2)
        #expect(log.texts[0] == String(localized: MacAMPStrings.chatDownloadAbandonedToast))
        #expect(log.texts[1] == String(localized: MacAMPStrings.chatDownloadPlaylistMissingToast))
    }

    @Test("held and already-a-member open no window and say nothing")
    func theSilentCasesSayNothing() async {
        let log = ToastLog()
        let coalescer = Self.make(log: log, names: [:])

        coalescer.record(.heldForProposal(UUID()))
        coalescer.record(.alreadyInPlaylist(playlistId: 1, trackId: 1))
        await coalescer.waitForPendingWindow()

        #expect(log.texts.isEmpty)
    }

    /// An append that lands while the closing window is resolving names belongs to the
    /// NEXT window, not to a sentence already being written.
    @Test("a second batch after the window closes gets its own sentence")
    func aSecondBatchGetsItsOwnSentence() async {
        let log = ToastLog()
        let coalescer = Self.make(log: log, names: [3: "Mix"])

        coalescer.record(.appended(playlistId: 3, trackId: 1))
        await coalescer.waitForPendingWindow()
        coalescer.record(.appended(playlistId: 3, trackId: 2))
        await coalescer.waitForPendingWindow()

        #expect(log.texts == [
            MacAMPStrings.chatDownloadAddedToast(1, playlist: "Mix"),
            MacAMPStrings.chatDownloadAddedToast(1, playlist: "Mix"),
        ])
    }

    private static func make(log: ToastLog, names: [Int64: String]) -> ChatDownloadToastCoalescer {
        ChatDownloadToastCoalescer(
            emit: { toast in log.record(toast) },
            playlistName: { names[$0] },
            window: .milliseconds(1)
        )
    }
}

/// Records every sentence the coalescer decided to say, in order.
final class ToastLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ChatDownloadToast] = []

    var texts: [String] {
        lock.withLock { entries.map(\.text) }
    }

    func record(_ toast: ChatDownloadToast) {
        lock.withLock { entries.append(toast) }
    }
}
