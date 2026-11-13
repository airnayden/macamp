// The rig for the parallel-driver suite: a runner that answers by VIDEO ID, an
// N-arrival barrier, and a service wired to both.
//
// `FakeToolProcessRunner` hands out its scripts POSITIONALLY. That is exactly right for
// a serial driver — spawn order is the run — and unusable for a parallel one, where
// three transfers race into the same script queue and each takes whichever entry
// happened to be next. Every assertion built on it would then be measuring the race
// rather than the behaviour. `VideoScriptedRunner` keys on the id the arguments already
// carry, so N concurrent rows replay reproducibly.
//
// The engine wire-format literals come from `DownloadFixture`, which restates them by
// hand — the same double-entry discipline, inherited rather than re-derived.
import Foundation
import PlayerCoreTestSupport
@testable import Services
import Testing

/// Releases every caller only once `count` of them have arrived, or once `timeout`
/// elapses — whichever comes first.
///
/// This is the overlap PROOF, not a synchronization convenience. Three rows that truly
/// run at once all reach `arrive` before any of them is released; a serial driver can
/// never get past the first, because the row holding the barrier is the only one
/// running. The timeout exists so that failure reads as a failed assertion
/// (``timedOut``) instead of a hung suite.
actor TransferBarrier {
    private let count: Int
    private let timeout: Duration
    private var arrived: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseTask: Task<Void, Never>?
    private(set) var timedOut = false

    init(count: Int, timeout: Duration = .seconds(4)) {
        self.count = count
        self.timeout = timeout
    }

    /// Records `id` as having reached the barrier and suspends until it opens.
    func arrive(_ id: String) async {
        arrived.append(id)
        guard arrived.count < count else {
            releaseAll()
            return
        }
        startTimeoutIfNeeded()
        await withCheckedContinuation { waiters.append($0) }
    }

    /// The ids that reached the barrier, in arrival order.
    var arrivals: [String] {
        arrived
    }

    private func startTimeoutIfNeeded() {
        guard releaseTask == nil else { return }
        let timeout = timeout
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.releaseOnTimeout()
        }
    }

    private func releaseOnTimeout() {
        guard !waiters.isEmpty else { return }
        timedOut = true
        releaseAll()
    }

    private func releaseAll() {
        releaseTask?.cancel()
        releaseTask = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// A ``ToolProcessRunning`` that answers by canonical video id rather than spawn order.
final class VideoScriptedRunner: ToolProcessRunning, @unchecked Sendable {
    /// Awaited mid-transfer, between the two progress samples. A barrier installed here
    /// is what forces the rows to genuinely overlap before any of them may finish.
    typealias TransferGate = @Sendable (String) async -> Void

    private let lock = NSLock()
    private let videoIDs: [String]
    private let titles: [String: String]
    private let terminations: [String: ProcessTermination]
    private let gate: TransferGate?
    private var spawned: [ToolSpawnRequest] = []

    /// - Parameters:
    ///   - videoIDs: Every id this runner will be asked about. The id is recovered by
    ///     matching against this list rather than by parsing the URL, so the runner
    ///     never re-derives the production normalizer's behaviour.
    ///   - titles: The `-J` title per id, so an enrichment that crossed rows is visible
    ///     as the WRONG title rather than merely as a missing one.
    ///   - terminations: How one id's transfer ends, when not a clean exit. A row listed
    ///     here reports NO file line, so its outcome comes from the termination alone —
    ///     which is what makes "one row's failure never drains its siblings" a statement
    ///     about the production map rather than about this double.
    init(
        videoIDs: [String],
        titles: [String: String] = [:],
        terminations: [String: ProcessTermination] = [:],
        gate: TransferGate? = nil
    ) {
        self.videoIDs = videoIDs
        self.titles = titles
        self.terminations = terminations
        self.gate = gate
    }

    func spawn(
        tool: URL,
        arguments: [String]
    ) async throws -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        lock.withLock { spawned.append(ToolSpawnRequest(tool: tool, arguments: arguments)) }
        guard let videoID = videoID(in: arguments) else { return Self.stream(emitting: []) }
        guard !arguments.contains("--flat-playlist") else {
            return Self.stream(emitting: [.stdout(infoDocument(for: videoID))])
        }
        return transferStream(for: videoID)
    }

    /// Every spawn this runner received, in arrival order.
    var spawnRequests: [ToolSpawnRequest] {
        lock.withLock { spawned }
    }

    /// How many TRANSFERS (not prefetches) this runner was asked for.
    var transferCount: Int {
        spawnRequests.count { !$0.arguments.contains("--flat-playlist") }
    }

    // MARK: - Internals

    private func videoID(in arguments: [String]) -> String? {
        guard let last = arguments.last else { return nil }
        return videoIDs.first { last.contains($0) }
    }

    private func infoDocument(for videoID: String) -> String {
        DownloadFixture.info(
            id: videoID,
            title: titles[videoID] ?? "Track \(videoID)",
            uploader: "Uploader \(videoID)"
        )
    }

    /// Two progress samples straddling the gate, then the post-process and file lines.
    ///
    /// Straddling is what makes interleaving STRUCTURAL: every row's second sample is
    /// published after every row's first, so the recorded sequence cannot be three
    /// contiguous blocks unless the driver ran them one at a time.
    private func transferStream(for videoID: String) -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        let gate = gate
        let filePath = Self.finishedPath(for: videoID)
        let failure = terminations[videoID]
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.stdout(DownloadFixture.quarterProgress))
                await gate?(videoID)
                continuation.yield(.stdout(DownloadFixture.halfProgress))
                if let failure {
                    continuation.yield(.terminated(failure))
                    continuation.finish()
                    return
                }
                continuation.yield(.stderr(DownloadFixture.postProcessLine))
                continuation.yield(.stdout("MACAMP-FILE|" + filePath))
                continuation.yield(.terminated(.success))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The `after_move` path a row for `videoID` reports.
    static func finishedPath(for videoID: String) -> String {
        "/tmp/macamp-downloads/Track [\(videoID)].m4a"
    }

    private static func stream(
        emitting lines: [ToolOutputEvent]
    ) -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        AsyncThrowingStream { continuation in
            for line in lines {
                continuation.yield(line)
            }
            continuation.yield(.terminated(.success))
            continuation.finish()
        }
    }
}

/// A `DownloadQueueService` wired to a ``VideoScriptedRunner`` and the shared recorder.
@MainActor
struct ConcurrentDownloadHarness {
    let runner: VideoScriptedRunner
    let recorder = DownloadQueueRecorder()
    let service: DownloadQueueService
    let videoIDs: [String]

    init(
        videoIDs: [String],
        titles: [String: String] = [:],
        terminations: [String: ProcessTermination] = [:],
        maxConcurrent: @escaping @Sendable () -> Int,
        format: @escaping @Sendable () -> DownloadFormat = { .default },
        staging: URL = URL(fileURLWithPath: "/tmp/macamp-staging", isDirectory: true),
        gate: VideoScriptedRunner.TransferGate? = nil
    ) {
        self.videoIDs = videoIDs
        runner = VideoScriptedRunner(
            videoIDs: videoIDs,
            titles: titles,
            terminations: terminations,
            gate: gate
        )
        let destination = URL(fileURLWithPath: "/tmp/macamp-downloads-\(UUID().uuidString)", isDirectory: true)
        service = DownloadQueueService(
            toolProvider: FakeDownloadToolProvider(),
            processRunner: runner,
            stagingDirectory: staging,
            destinationDirectory: { destination },
            downloadFormat: format,
            isDirectoryWritable: { _ in true },
            maxConcurrent: maxConcurrent
        )
        let sink = recorder
        service.onQueueChanged = { sink.record(snapshot: $0) }
        service.onItemProgress = { sink.record(id: $0, state: $1) }
        service.onItemFinished = { sink.record(item: $0, fileURL: $1) }
    }

    /// Enqueues just `ids`, which the runner must already know about.
    ///
    /// The two lists are separate on purpose: a test that appends rows LATER still has
    /// to declare their ids up front so the runner can answer for them, and enqueuing
    /// the whole roster would make that later append a no-op — every id would already be
    /// queued, and dedup would silently drop it.
    func enqueue(ids: [String]) async -> EnqueueOutcome {
        let urls = ids.compactMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
        return await service.enqueue(urls: urls)
    }

    /// Enqueues every id this harness knows about, in order.
    func enqueueAll() async -> EnqueueOutcome {
        await enqueue(ids: videoIDs)
    }

    func waitUntil(timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitForTerminals(_ count: Int, timeout: Duration = .seconds(10)) async {
        let sink = recorder
        await waitUntil(timeout: timeout) { sink.terminalCount >= count }
    }
}

extension ConcurrentDownloadHarness {
    /// Runs `action` on the main actor the first time any row reports `.downloading`.
    ///
    /// The seam is awaited by the driver before it reads the next engine line, so an act
    /// raised here is guaranteed to have fully landed while the row is still mid-transfer.
    func onFirstDownloadingRow(
        _ action: @escaping @Sendable @MainActor (DownloadQueueService, UUID) -> Void
    ) {
        let sink = recorder
        let service = service
        let latch = OneShotLatch()
        service.onItemProgress = { id, state in
            sink.record(id: id, state: state)
            guard case .downloading = state, latch.fire() else { return }
            MainActor.assumeIsolated { action(service, id) }
        }
    }

    /// Runs `action` on the main actor the first time any row reaches a terminal state.
    func onFirstTerminal(_ action: @escaping @Sendable @MainActor () -> Void) {
        let sink = recorder
        let latch = OneShotLatch()
        service.onItemProgress = { id, state in
            sink.record(id: id, state: state)
            guard state.isTerminal, latch.fire() else { return }
            MainActor.assumeIsolated { action() }
        }
    }

    /// Cancels the first row to report `.downloading`, recording which one that was.
    func cancelFirstDownloadingRow(into box: CancelledRowBox) {
        onFirstDownloadingRow { service, id in
            guard let item = service.active.first(where: { $0.id == id }) else { return }
            box.capture(item.canonicalVideoID)
            service.cancel(itemID: id)
        }
    }

    /// The row id a canonical video id was enqueued under, from the recorded snapshots.
    func idOfRow(videoID: String) -> UUID? {
        for snapshot in recorder.snapshots {
            let rows = snapshot.activeItems + snapshot.pendingItems
            if let match = rows.first(where: { $0.canonicalVideoID == videoID }) {
                return match.id
            }
        }
        return nil
    }
}

/// The row a per-item cancel was aimed at, captured as it happened.
///
/// Which of two genuinely-parallel rows publishes its first sample first is not a fact a
/// test may assert, so the cancel targets whichever one it is and records the answer.
final class CancelledRowBox: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: String?

    func capture(_ videoID: String) {
        lock.withLock { captured = videoID }
    }

    var videoID: String? {
        lock.withLock { captured }
    }
}

/// Which seeded staging artifacts were still on disk at the instant a cancel returned.
final class SurvivingArtifactsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String] = []

    func record(_ names: [String]) {
        lock.withLock { captured = names }
    }

    var names: [String] {
        lock.withLock { captured }
    }
}

/// A concurrency limit a test can change mid-run, read through the service's own
/// `@Sendable` closure.
final class ConcurrencyLimitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int

    init(_ value: Int) {
        stored = value
    }

    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension DownloadQueueRecorder {
    /// The most rows any published snapshot reported in flight at once.
    var peakActiveCount: Int {
        snapshots.map(\.activeItems.count).max() ?? 0
    }

    /// The ids of every `.downloading` sample, in publication order.
    var downloadingIDs: [UUID] {
        progress.filter { if case .downloading = $0.state { true } else { false } }.map(\.id)
    }

    /// How many contiguous same-id blocks ``downloadingIDs`` forms.
    ///
    /// A driver that ran N rows one after another produces exactly N; anything higher
    /// means a row published between two of another row's samples.
    var downloadingRunCount: Int {
        downloadingIDs.reduce(into: [UUID]()) { runs, id in
            if runs.last != id { runs.append(id) }
        }.count
    }
}
