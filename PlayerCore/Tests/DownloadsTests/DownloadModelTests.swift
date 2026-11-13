// The Downloads value types: the frozen storage vocabulary, the lifecycle state
// machine, the typed error ladder, and the queue's snapshot/outcome/limit types.
import Foundation
import Services
import Testing

@Suite("Download format vocabulary")
struct DownloadFormatTests {
    /// Raw values are PERSISTED in settings. This test is the tripwire: renaming one
    /// silently invalidates every stored preference, so the mapping is pinned here.
    @Test("audio format raw values are the frozen storage vocabulary")
    func audioFormatRawValuesAreFrozen() {
        #expect(DownloadAudioFormat.m4a.rawValue == "m4a")
        #expect(DownloadAudioFormat.mp3.rawValue == "mp3")
        #expect(DownloadAudioFormat.opus.rawValue == "opus")
        #expect(DownloadAudioFormat.flac.rawValue == "flac")
        #expect(DownloadAudioFormat.allCases.count == 4)
    }

    @Test("audio quality raw values are the frozen storage vocabulary")
    func audioQualityRawValuesAreFrozen() {
        #expect(DownloadAudioQuality.best.rawValue == "best")
        #expect(DownloadAudioQuality.high.rawValue == "high")
        #expect(DownloadAudioQuality.medium.rawValue == "medium")
        #expect(DownloadAudioQuality.allCases.count == 3)
    }

    @Test("m4a at best quality is the default, and needs no transcode")
    func defaultsAreNativePassthrough() {
        #expect(DownloadAudioFormat.default == .m4a)
        #expect(DownloadAudioQuality.default == .best)
        #expect(DownloadFormat.default == .audio(.m4a, .best))
        #expect(!DownloadAudioFormat.m4a.requiresTranscode)
    }

    @Test("every non-default format transcodes through ffmpeg", arguments: [
        DownloadAudioFormat.mp3, .opus, .flac,
    ])
    func nonDefaultFormatsTranscode(format: DownloadAudioFormat) {
        #expect(format.requiresTranscode)
    }

    @Test("file extension matches the storage token", arguments: DownloadAudioFormat.allCases)
    func fileExtensionMatchesToken(format: DownloadAudioFormat) {
        #expect(format.fileExtension == format.rawValue)
        #expect(DownloadFormat.audio(format, .best).fileExtension == format.rawValue)
    }

    @Test("the engine vocabulary projects back onto the storage vocabulary")
    func engineVocabularyProjectsToStorage() {
        let format = DownloadFormat.audio(.flac, .medium)
        #expect(format.audioFormat == .flac)
        #expect(format.audioQuality == .medium)
    }
}

@Suite("Download lifecycle state")
struct DownloadStateTests {
    @Test("terminal states are exactly finished, failed, and cancelled")
    func terminalStates() {
        let file = URL(fileURLWithPath: "/tmp/song.m4a")
        #expect(DownloadState.finished(fileURL: file).isTerminal)
        #expect(DownloadState.failed(.toolMissing).isTerminal)
        #expect(DownloadState.cancelled.isTerminal)
        #expect(!DownloadState.queued.isTerminal)
        #expect(!DownloadState.fetchingMetadata.isTerminal)
        #expect(!DownloadState.postProcessing(fraction: nil).isTerminal)
        #expect(!DownloadState.downloading(fraction: 0.5, speedBytesPerSec: nil, etaSeconds: nil).isTerminal)
    }

    @Test("active states are exactly the three in-flight phases")
    func activeStates() {
        #expect(DownloadState.fetchingMetadata.isActive)
        #expect(DownloadState.postProcessing(fraction: nil).isActive)
        #expect(DownloadState.downloading(fraction: 0, speedBytesPerSec: nil, etaSeconds: nil).isActive)
        #expect(!DownloadState.queued.isActive)
        #expect(!DownloadState.cancelled.isActive)
    }

    @Test("fraction is clamped so a malformed engine sample cannot escape 0...1")
    func fractionIsClamped() {
        #expect(DownloadState.downloading(fraction: -3, speedBytesPerSec: nil, etaSeconds: nil).fraction == 0)
        #expect(DownloadState.downloading(fraction: 42, speedBytesPerSec: nil, etaSeconds: nil).fraction == 1)
        #expect(DownloadState.downloading(fraction: 0.25, speedBytesPerSec: 10, etaSeconds: 3).fraction == 0.25)
    }

    @Test("indeterminate phases report no fraction; finished reports 1")
    func indeterminateAndFinishedFractions() {
        #expect(DownloadState.queued.fraction == nil)
        #expect(DownloadState.fetchingMetadata.fraction == nil)
        #expect(DownloadState.postProcessing(fraction: nil).fraction == nil)
        #expect(DownloadState.cancelled.fraction == nil)
        #expect(DownloadState.failed(.cancelled).fraction == nil)
        #expect(DownloadState.finished(fileURL: URL(fileURLWithPath: "/tmp/a.m4a")).fraction == 1)
    }

    @Test("the typed error is reachable only from failed")
    func errorAccessor() {
        #expect(DownloadState.failed(.unknown(code: 7)).error == .unknown(code: 7))
        #expect(DownloadState.cancelled.error == nil)
    }
}

@Suite("Download queue value types")
struct DownloadQueueModelTests {
    static func makeItem(_ videoID: String) -> DownloadItem {
        DownloadItem(
            canonicalVideoID: videoID,
            sourceURL: URL(fileURLWithPath: "/dev/null")
        )
    }

    @Test("limits are the plan's owner-tunable caps")
    func limits() {
        #expect(DownloadQueueLimits.maxPlaylistExpansion == 500)
        #expect(DownloadQueueLimits.maxQueueDepth == 1000)
        #expect(DownloadQueueLimits.maxConcurrentDownloads == 4)
        #expect(DownloadQueueLimits.defaultConcurrentDownloads == 3)
        #expect(DownloadQueueLimits.defaultConcurrentDownloads <= DownloadQueueLimits.maxConcurrentDownloads)
    }

    /// The plural vocabulary at its narrowest: one transfer in flight is ONE ELEMENT of
    /// ``DownloadQueueSnapshot/activeItems``, not a singular optional beside the pending
    /// list. Cheap to state and cheap to keep, and it is what stops the shape regressing.
    @Test("a one-transfer snapshot carries that transfer in the active list")
    func singleActiveItemSnapshot() {
        let item = Self.makeItem("ddddddddddd")
        let snapshot = DownloadQueueSnapshot(activeItems: [item], pendingItems: [], isPaused: false)
        #expect(snapshot.activeItems == [item])
        #expect(snapshot.count == 1)
        #expect(!snapshot.isEmpty)
    }

    @Test("snapshot counts the in-flight row alongside the pending ones")
    func snapshotCounting() {
        let pending = [Self.makeItem("aaaaaaaaaaa"), Self.makeItem("bbbbbbbbbbb")]
        let running = DownloadQueueSnapshot(
            activeItems: [Self.makeItem("ccccccccccc")],
            pendingItems: pending,
            isPaused: false
        )
        #expect(running.count == 3)
        #expect(!running.isEmpty)
        #expect(DownloadQueueSnapshot.empty.count == 0)
        #expect(DownloadQueueSnapshot.empty.isEmpty)
        #expect(!DownloadQueueSnapshot.empty.isPaused)
    }

    /// The stale/discarded-token contract: `confirmPlaylist` answers with this, and
    /// the UI reports "0 added" rather than raising an error.
    @Test("the zero outcome changed nothing")
    func zeroOutcome() {
        #expect(EnqueueOutcome.zero == EnqueueOutcome(added: 0, duplicatesDropped: 0, pendingPlaylist: nil))
        #expect(EnqueueOutcome.zero.pendingPlaylist == nil)
    }

    @Test("a pending playlist carries its token, count, and capped flag")
    func pendingPlaylistPayload() {
        let token = UUID()
        let outcome = EnqueueOutcome(
            added: 2,
            duplicatesDropped: 1,
            pendingPlaylist: EnqueueOutcome.PendingPlaylist(token: token, count: 500, capped: true)
        )
        #expect(outcome.added == 2)
        #expect(outcome.duplicatesDropped == 1)
        #expect(outcome.pendingPlaylist?.token == token)
        #expect(outcome.pendingPlaylist?.count == DownloadQueueLimits.maxPlaylistExpansion)
        #expect(outcome.pendingPlaylist?.capped == true)
    }

    @Test("identity is the enqueue id, not the video id")
    func identityIsPerEnqueue() {
        let first = Self.makeItem("aaaaaaaaaaa")
        let second = Self.makeItem("aaaaaaaaaaa")
        #expect(first.id != second.id)
        #expect(first.canonicalVideoID == second.canonicalVideoID)
    }

    @Test("display title falls back to the canonical id until metadata arrives")
    func displayTitleFallback() {
        var item = Self.makeItem("dQw4w9WgXcQ")
        #expect(item.displayTitle == "dQw4w9WgXcQ")
        item.title = "Never Gonna Give You Up"
        #expect(item.displayTitle == "Never Gonna Give You Up")
    }

    @Test("a fresh item is queued with no metadata")
    func freshItemDefaults() {
        let item = Self.makeItem("dQw4w9WgXcQ")
        #expect(item.state == .queued)
        #expect(item.title == nil)
        #expect(item.uploader == nil)
        #expect(item.durationSeconds == nil)
        #expect(item.thumbnailURL == nil)
    }

    @Test("download outcomes are distinguishable")
    func outcomeVocabulary() {
        #expect(DownloadOutcome.completed(filePath: "/tmp/a.m4a") != .completed(filePath: "/tmp/b.m4a"))
        #expect(DownloadOutcome.failed(.toolMissing) != .failed(.cancelled))
    }
}
