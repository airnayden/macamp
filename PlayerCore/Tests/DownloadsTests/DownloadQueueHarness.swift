// The shared rig for the two `DownloadQueueService` suites: a scripted process runner, a
// lock-guarded sink for the three `@Sendable` seams, and the engine wire-format literals
// the scripts are written in.
//
// The literals are restated here rather than composed from `YtDlpSentinel` on purpose —
// same double-entry discipline as `YtDlpCommandBuilderTests`. A test that built its input
// from the production constant would keep agreeing with whatever that constant became.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

/// One `onItemProgress` callback, as a value.
struct DownloadProgressEvent: Equatable {
    let id: UUID
    let state: DownloadState
}

/// One `onItemFinished` callback, as a value.
struct DownloadFinishedEvent: Equatable {
    let item: DownloadItem
    let fileURL: URL
}

/// Collects the three `@Sendable` seams. Lock-guarded by contract: the closures fire on
/// the main actor, but their type is `@Sendable`.
final class DownloadQueueRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotEvents: [DownloadQueueSnapshot] = []
    private var progressEvents: [DownloadProgressEvent] = []
    private var finishedEvents: [DownloadFinishedEvent] = []

    func record(snapshot: DownloadQueueSnapshot) {
        lock.withLock { snapshotEvents.append(snapshot) }
    }

    func record(id: UUID, state: DownloadState) {
        lock.withLock { progressEvents.append(DownloadProgressEvent(id: id, state: state)) }
    }

    func record(item: DownloadItem, fileURL: URL) {
        lock.withLock { finishedEvents.append(DownloadFinishedEvent(item: item, fileURL: fileURL)) }
    }

    var snapshots: [DownloadQueueSnapshot] {
        lock.withLock { snapshotEvents }
    }

    var progress: [DownloadProgressEvent] {
        lock.withLock { progressEvents }
    }

    var finished: [DownloadFinishedEvent] {
        lock.withLock { finishedEvents }
    }

    var latestSnapshot: DownloadQueueSnapshot {
        lock.withLock { snapshotEvents.last ?? .empty }
    }

    /// Every state published for `id`, in order.
    func states(of id: UUID) -> [DownloadState] {
        progress.filter { $0.id == id }.map(\.state)
    }

    /// How many rows have reached a terminal state — the fence every wait uses.
    var terminalCount: Int {
        progress.count(where: { $0.state.isTerminal })
    }
}

/// A scripted writability probe: answers `results` in order, then `fallback` forever.
///
/// Sequenced rather than fixed because the load-bearing assertion is that ONE unwritable
/// destination fails ONE row without draining the queue — a probe that always answered
/// `false` could not tell that apart from a queue that stopped.
final class DownloadWritabilityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool]
    private let fallback: Bool
    private var calls: [URL] = []

    init(results: [Bool] = [], fallback: Bool = true) {
        self.results = results
        self.fallback = fallback
    }

    func probe(_ url: URL) -> Bool {
        lock.withLock {
            calls.append(url)
            return results.isEmpty ? fallback : results.removeFirst()
        }
    }

    var probedURLs: [URL] {
        lock.withLock { calls }
    }
}

/// A `DownloadQueueService` plus the doubles it was built from.
@MainActor
struct DownloadQueueHarness {
    let runner: FakeToolProcessRunner
    let provider: FakeDownloadToolProvider
    let recorder = DownloadQueueRecorder()
    let probe: DownloadWritabilityProbe
    let destination: URL
    let staging: URL
    let service: DownloadQueueService

    /// - Parameters:
    ///   - staging: Injectable so the staging-purge suite can seed a REAL directory and
    ///     assert what survives an interruption. The default is the original inert path:
    ///     no test that ignores it touches the filesystem, because a purge over a
    ///     directory that does not exist reads nothing and removes nothing.
    ///   - maxConcurrent: Defaults to ONE, which is not the production default and is
    ///     deliberate. `FakeToolProcessRunner` hands out its scripts POSITIONALLY, so a
    ///     script list only describes a run whose spawn order is fixed — which is exactly
    ///     what one slot gives and what more than one takes away. Every suite built on
    ///     scripted spawn order therefore keeps stating the serial contract through the
    ///     same code path the parallel one runs; overlap is measured in the concurrency
    ///     suite, on a runner that answers by video id instead.
    ///   - oEmbed: The paste-time decoration seam. `nil` — the default — leaves it
    ///     switched off, which is what every suite written before it existed expects:
    ///     a pending row keeps showing its canonical id until `-J` runs.
    init(
        scripts: [ToolProcessScript] = [],
        probe: DownloadWritabilityProbe = DownloadWritabilityProbe(),
        provider: FakeDownloadToolProvider = FakeDownloadToolProvider(),
        staging: URL = URL(fileURLWithPath: "/tmp/macamp-staging", isDirectory: true),
        maxConcurrent: Int = 1,
        oEmbed: (any OEmbedFetching)? = nil
    ) {
        runner = FakeToolProcessRunner(scripts: scripts)
        self.provider = provider
        self.probe = probe
        self.staging = staging
        destination = URL(fileURLWithPath: "/tmp/macamp-downloads-\(UUID().uuidString)", isDirectory: true)
        let destinationDirectory = destination
        let writability = probe
        service = DownloadQueueService(
            toolProvider: provider,
            processRunner: runner,
            stagingDirectory: staging,
            destinationDirectory: { destinationDirectory },
            downloadFormat: { .default },
            isDirectoryWritable: { writability.probe($0) },
            maxConcurrent: { maxConcurrent },
            oEmbedFetcher: oEmbed
        )
        let sink = recorder
        service.onQueueChanged = { sink.record(snapshot: $0) }
        service.onItemProgress = { sink.record(id: $0, state: $1) }
        service.onItemFinished = { sink.record(item: $0, fileURL: $1) }
    }

    /// The ids of the rows currently queued, in the driver's pick order.
    var queuedIDs: [UUID] {
        let snapshot = recorder.latestSnapshot
        return snapshot.activeItems.map(\.id) + snapshot.pendingItems.map(\.id)
    }

    /// The id of the first row ever published, i.e. the one enqueued first.
    func firstEnqueuedID() throws -> UUID {
        try #require(recorder.progress.first?.id)
    }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Waits until `count` rows have reached a terminal state.
    func waitForTerminals(_ count: Int, timeout: Duration = .seconds(5)) async {
        let sink = recorder
        await waitUntil(timeout: timeout) { sink.terminalCount >= count }
    }

    /// Waits until the queue has parked: the paused latch set AND nothing in flight.
    ///
    /// Under refill-stop those are two independent facts rather than one. `pause()` only
    /// sets the latch; the active row empties because it RAN TO COMPLETION and settled.
    /// So this waits for a row to finish on its own, not for one to be torn down — which
    /// is why every caller must also assert what that row's terminal state was.
    func waitForPausedIdle(timeout: Duration = .seconds(5)) async {
        let sink = recorder
        await waitUntil(timeout: timeout) {
            let snapshot = sink.latestSnapshot
            return snapshot.isPaused && snapshot.activeItems.isEmpty
        }
    }

    /// Runs `action` on the main actor the first time any row reports `.downloading`.
    ///
    /// `assumeIsolated` states the seam's own contract ("invoked on the main actor")
    /// rather than dodging it — and it is what makes "pause/cancel MID-download"
    /// deterministic. Awaiting the publish inside the driver guarantees `action` has
    /// fully run before the next engine line is read, so there is no sleep to race.
    func interruptOnFirstDownloadTick(
        _ action: @escaping @Sendable @MainActor (DownloadQueueService) -> Void
    ) {
        let sink = recorder
        let queue = service
        let latch = OneShotLatch()
        service.onItemProgress = { id, state in
            sink.record(id: id, state: state)
            guard case .downloading = state, latch.fire() else { return }
            MainActor.assumeIsolated { action(queue) }
        }
    }
}

/// Fires exactly once, whoever asks first.
final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.withLock {
            defer { fired = true }
            return !fired
        }
    }
}

// MARK: - Engine wire-format fixtures

/// The engine output lines and `-J` documents the scripts are written in.
enum DownloadFixture {
    static let videoID = "dQw4w9WgXcQ"
    static let otherVideoID = "9bZkp7q19f0"
    static let thirdVideoID = "kJQP7kiw5Fk"

    static let watchURL = "https://www.youtube.com/watch?v=\(videoID)"
    static let otherWatchURL = "https://www.youtube.com/watch?v=\(otherVideoID)"
    /// The same video as ``watchURL`` in a different family, with query noise — the
    /// dedup tests need a duplicate that is not a string match.
    static let shortWatchURL = "https://youtu.be/\(videoID)?t=42&si=abcdef"
    static let playlistURL = "https://www.youtube.com/playlist?list=PLmacampdownloads"

    static let finishedPath = "/tmp/macamp-downloads/Never Gonna Give You Up [\(videoID)].m4a"
    static let fileLine = "MACAMP-FILE|\(finishedPath)"
    static let postProcessLine = "MACAMP-PP|processing|ExtractAudio"

    /// `MACAMP-P|status|downloaded|total|estimate|eta|speed` — six fields, always.
    static func progressLine(downloaded: Int, total: Int, eta: Int, speed: Int) -> String {
        "MACAMP-P|downloading|\(downloaded)|\(total)|NA|\(eta)|\(speed).0"
    }

    static let quarterProgress = progressLine(downloaded: 262_144, total: 1_048_576, eta: 6, speed: 131_072)
    static let halfProgress = progressLine(downloaded: 524_288, total: 1_048_576, eta: 3, speed: 262_144)

    /// The `-J` document for a single video.
    static func info(
        id: String = videoID,
        title: String = "Never Gonna Give You Up",
        uploader: String = "Rick Astley",
        duration: Double = 213
    ) -> String {
        """
        {"id":"\(id)","title":"\(title)","uploader":"\(uploader)","duration":\(duration),\
        "thumbnail":"https://i.ytimg.com/vi/\(id)/hq.jpg"}
        """
    }

    /// The `--flat-playlist -J` document for a playlist of `ids`.
    static func playlist(ids: [String]) -> String {
        let entries = ids.map { #"{"_type":"url","id":"\#($0)","title":"Track \#($0)"}"# }
        return #"{"_type":"playlist","id":"PLmacampdownloads","entries":["# + entries.joined(separator: ",") + "]}"
    }

    /// `count` distinct, well-formed 11-character video ids.
    static func generatedIDs(count: Int) -> [String] {
        (0 ..< count).map { "PLVID" + String(format: "%06d", $0) }
    }

    /// The clean metadata prefetch that precedes every download spawn.
    static func infoScript(id: String = videoID) -> ToolProcessScript {
        .success(stdout: [info(id: id)])
    }

    /// A download that ticks twice, post-processes, and reports its moved file.
    static let happyDownloadScript = ToolProcessScript.success(stdout: [
        quarterProgress,
        halfProgress,
        postProcessLine,
        fileLine,
    ])

    // MARK: - The real capture (measured 2026-09-10)

    /// The eight `postprocess:` sentinel lines one real run emitted — every one of them
    /// on STDERR, which is where yt-dlp writes that template. Restated verbatim rather
    /// than generated, so a script written from them replays the engine rather than the
    /// app's idea of it.
    static let postProcessStderrLines = [
        "MACAMP-PP|started|ExtractAudio",
        "MACAMP-PP|processing|ExtractAudio",
        "MACAMP-PP|finished|ExtractAudio",
        "MACAMP-PP|started|EmbedThumbnail",
        "MACAMP-PP|finished|EmbedThumbnail",
        "MACAMP-PP|started|MoveFiles",
        "MACAMP-PP|processing|MoveFiles",
        "MACAMP-PP|finished|MoveFiles",
    ]

    /// The transfer's last sample: status `finished`, downloaded == total. It is still a
    /// `MACAMP-P|` line, so it parses as `.downloading` at fraction 1 — which is exactly
    /// what a row showed for the whole post-processing phase before stderr was parsed.
    static let finishedProgress = "MACAMP-P|finished|252182|252182|NA|NA|107374.4"

    /// The eight `downloading` samples that preceded it, on stdout.
    static let capturedProgressLines = (1 ... 8).map {
        progressLine(downloaded: 31522 * $0, total: 252_182, eta: 8 - $0, speed: 107_374)
    }

    /// One real run, replayed with its two streams SPLIT the way the engine writes them:
    /// progress and the `--print` path on stdout, post-processing on stderr, and the
    /// file line arriving LAST — after every post-process sentinel.
    static let realCaptureScript = ToolProcessScript(
        lines: capturedProgressLines.map(ToolOutputEvent.stdout)
            + [.stdout(finishedProgress)]
            + postProcessStderrLines.map(ToolOutputEvent.stderr)
            + [.stdout(fileLine)],
        termination: .success
    )
}
