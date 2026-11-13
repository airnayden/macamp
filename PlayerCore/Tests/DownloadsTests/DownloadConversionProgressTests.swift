// End-to-end coverage for conversion progress: the queue really spawns, the poller
// really reads the file the BUILDER named, and the seam really coalesces.
//
// ── WHY THIS DRIVES THE WHOLE SERVICE RATHER THAN THE TAILER ─────────────────
//
// `FFProgressFileTailerTests` proves the arithmetic. It cannot prove any of the four
// things that actually break in production: that the poller runs at all, that it polls
// the path the argument vector asked ffmpeg to write (this test extracts that path OUT
// of the recorded spawn arguments rather than rebuilding it, so a builder/poller
// disagreement fails here), that the duration captured at spawn reaches it, and that
// `emitItemState`'s same-value suppression still behaves with the richer payload.
//
// ── THE SUPPRESSION ASSERTION IS THE COUNT ───────────────────────────────────
//
// The poller ticks four times a second for the whole phase, so a run that publishes
// `nil`, `0.4`, `0.8`, `nil` at the seam emitted WELL over a dozen samples underneath —
// the `nil`s before the first sample, every repeat of `0.4` and `0.8` while the file sat
// unchanged, and every repeat of `nil` after the terminal block. `count == 4` is
// therefore the coalescing claim: without suppression this array is long, and with a
// suppression that dropped too much it is short. The two distinct fractions in the
// middle are the other half — a guard that coalesced by phase rather than by value
// would collapse them.
//
// `FakeToolProcessRunner` cannot host this: it yields every scripted line and finishes
// synchronously, so the drain loop exits (and its `defer` cancels the poller) before a
// single 250 ms tick. `HeldConversionRunner` is the smallest thing that keeps a spawn
// open, which is what a real conversion does.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

/// A two-spawn runner whose DOWNLOAD stream stays open until the test releases it.
///
/// Spawn 1 is the `-J` prefetch (recognised by the flag, not by call order, so a future
/// extra spawn cannot silently shift the script). Spawn 2 announces post-processing and
/// then waits — which is exactly the window a real ffmpeg transcode occupies and the only
/// window in which the poller can run.
final class HeldConversionRunner: ToolProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var release: (@Sendable () -> Void)?
    private let releasedSignal = AsyncStream.makeStream(of: Void.self)

    let infoDocument: String
    let postProcessLine: String
    let fileLine: String

    init(infoDocument: String, postProcessLine: String, fileLine: String) {
        self.infoDocument = infoDocument
        self.postProcessLine = postProcessLine
        self.fileLine = fileLine
    }

    var spawnedArguments: [[String]] {
        lock.withLock { recorded }
    }

    /// Lets the held download finish. Safe to call more than once.
    func releaseTransfer() {
        releasedSignal.continuation.finish()
    }

    func spawn(tool _: URL, arguments: [String]) async throws -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        lock.withLock { recorded.append(arguments) }
        if arguments.contains("-J") {
            return prefetchStream()
        }
        return transferStream()
    }

    private func prefetchStream() -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.stdout(infoDocument))
            continuation.yield(.terminated(.success))
            continuation.finish()
        }
    }

    private func transferStream() -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        let signal = releasedSignal.stream
        let postProcess = postProcessLine
        let file = fileLine
        return AsyncThrowingStream { continuation in
            let work = Task {
                continuation.yield(.stderr(postProcess))
                for await _ in signal {}
                continuation.yield(.stdout(file))
                continuation.yield(.terminated(.success))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

@MainActor
@Suite("Download conversion progress")
struct DownloadConversionProgressTests {
    /// 100 s makes `out_time_us` the percentage times 1e6, so the fixtures below read as
    /// the fractions they are meant to produce.
    static let duration: Double = 100

    static func block(microseconds: Int, terminator: String = "continue") -> String {
        "out_time_us=\(microseconds)\nprogress=\(terminator)\n"
    }

    /// The conversion progress path as the ENGINE was told it, recovered from the
    /// recorded argument vector by stripping the prefix and the two literal quotes.
    ///
    /// Recovered rather than rebuilt on purpose: a test that composed this from
    /// `YtDlpCommandBuilder` would write to wherever the builder says regardless of what
    /// the vector carried, and would pass even if the quoting broke the value in half.
    static func progressFile(inSpawnedArguments vectors: [[String]]) throws -> URL {
        let vector = try #require(vectors.first { $0.contains("--postprocessor-args") })
        let index = try #require(vector.firstIndex(of: "--postprocessor-args"))
        let value = vector[index + 1]
        let prefix = "ExtractAudio+ffmpeg:-progress \""
        #expect(value.hasPrefix(prefix))
        #expect(value.hasSuffix("\""))
        return URL(fileURLWithPath: String(value.dropFirst(prefix.count).dropLast()))
    }

    static func makeStaging() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macamp-ffprogress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makeService(
        runner: HeldConversionRunner,
        staging: URL,
        recorder: DownloadQueueRecorder
    ) -> DownloadQueueService {
        let destination = URL(fileURLWithPath: "/tmp/macamp-downloads", isDirectory: true)
        let service = DownloadQueueService(
            toolProvider: FakeDownloadToolProvider(),
            processRunner: runner,
            stagingDirectory: staging,
            destinationDirectory: { destination },
            downloadFormat: { .default },
            isDirectoryWritable: { _ in true },
            maxConcurrent: { 1 }
        )
        service.onItemProgress = { recorder.record(id: $0, state: $1) }
        return service
    }

    static func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Every fraction published while the row was post-processing, in order — `.some(nil)`
    /// for an indeterminate publication, so a dropped `nil` is distinguishable from a
    /// dropped sample.
    nonisolated static func conversionFractions(in recorder: DownloadQueueRecorder) -> [Double?] {
        recorder.progress.compactMap { event -> Double?? in
            guard case let .postProcessing(fraction) = event.state else { return nil }
            return .some(fraction)
        }
    }

    @Test("a conversion publishes nil, its real samples, then nil again — each exactly once")
    func aConversionPublishesItsSamplesOnceEach() async throws {
        let staging = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let recorder = DownloadQueueRecorder()
        let runner = HeldConversionRunner(
            infoDocument: DownloadFixture.info(duration: Self.duration),
            postProcessLine: DownloadFixture.postProcessLine,
            fileLine: DownloadFixture.fileLine
        )
        let service = Self.makeService(runner: runner, staging: staging, recorder: recorder)

        _ = try await service.enqueue(urls: [downloadTestURL(DownloadFixture.watchURL)])
        await Self.waitUntil { !Self.conversionFractions(in: recorder).isEmpty }

        // Two full poll intervals of an ABSENT file, so the run really does produce the
        // repeated indeterminate publications the count below claims were coalesced.
        try? await Task.sleep(for: .milliseconds(600))
        let progressFile = try Self.progressFile(inSpawnedArguments: runner.spawnedArguments)
        var contents = Self.block(microseconds: 40_000_000)
        try Data(contents.utf8).write(to: progressFile, options: .atomic)
        await Self.waitUntil { Self.conversionFractions(in: recorder).count >= 2 }

        contents += Self.block(microseconds: 80_000_000)
        try Data(contents.utf8).write(to: progressFile, options: .atomic)
        await Self.waitUntil { Self.conversionFractions(in: recorder).count >= 3 }

        contents += Self.block(microseconds: 100_000_000, terminator: "end")
        try Data(contents.utf8).write(to: progressFile, options: .atomic)
        await Self.waitUntil { Self.conversionFractions(in: recorder).count >= 4 }
        runner.releaseTransfer()
        await Self.waitUntil { recorder.terminalCount >= 1 }

        let fractions = Self.conversionFractions(in: recorder)
        try #require(fractions.count == 4)
        #expect(fractions[0] == nil)
        #expect(try abs(#require(fractions[1]) - 0.4) < 1e-9)
        #expect(try abs(#require(fractions[2]) - 0.8) < 1e-9)
        #expect(fractions[3] == nil)
    }

    /// A failed `-J` prefetch leaves no duration, so there is no denominator and the row
    /// must sit on the indeterminate indicator for the whole phase — one publication, no
    /// matter how many samples ffmpeg wrote or how long the poller ran.
    @Test("an unknown duration keeps the whole conversion indeterminate")
    func anUnknownDurationStaysIndeterminate() async throws {
        let staging = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let recorder = DownloadQueueRecorder()
        let runner = HeldConversionRunner(
            infoDocument: "not a json document at all",
            postProcessLine: DownloadFixture.postProcessLine,
            fileLine: DownloadFixture.fileLine
        )
        let service = Self.makeService(runner: runner, staging: staging, recorder: recorder)

        _ = try await service.enqueue(urls: [downloadTestURL(DownloadFixture.watchURL)])
        await Self.waitUntil { !Self.conversionFractions(in: recorder).isEmpty }
        let progressFile = try Self.progressFile(inSpawnedArguments: runner.spawnedArguments)
        try Data(Self.block(microseconds: 40_000_000).utf8).write(to: progressFile, options: .atomic)
        try? await Task.sleep(for: .milliseconds(800))
        runner.releaseTransfer()
        await Self.waitUntil { recorder.terminalCount >= 1 }

        #expect(Self.conversionFractions(in: recorder) == [Double?.none])
    }

    /// A SUCCESS runs no purge — nothing was interrupted — so without an explicit
    /// reclamation the staging directory grows by one progress file per finished
    /// download until the next launch sweep ages it out. Measured on a real run before
    /// it was fixed (`.omo/evidence/dlv2-09.txt` §9).
    @Test("a completed download leaves no progress file behind")
    func aCompletedDownloadLeavesNoProgressFile() async throws {
        let staging = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let recorder = DownloadQueueRecorder()
        let runner = HeldConversionRunner(
            infoDocument: DownloadFixture.info(duration: Self.duration),
            postProcessLine: DownloadFixture.postProcessLine,
            fileLine: DownloadFixture.fileLine
        )
        let service = Self.makeService(runner: runner, staging: staging, recorder: recorder)

        _ = try await service.enqueue(urls: [downloadTestURL(DownloadFixture.watchURL)])
        await Self.waitUntil { !Self.conversionFractions(in: recorder).isEmpty }
        let progressFile = try Self.progressFile(inSpawnedArguments: runner.spawnedArguments)
        try Data(Self.block(microseconds: 100_000_000, terminator: "end").utf8)
            .write(to: progressFile, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: progressFile.path))

        runner.releaseTransfer()
        await Self.waitUntil { recorder.terminalCount >= 1 }

        #expect(recorder.progress.last?.state.isTerminal == true)
        #expect(!FileManager.default.fileExists(atPath: progressFile.path))
    }

    /// The file is engine bookkeeping and must never survive the row that made it.
    @Test("cancelling mid-conversion reclaims the progress file")
    func cancellingMidConversionReclaimsTheProgressFile() async throws {
        let staging = try Self.makeStaging()
        defer { try? FileManager.default.removeItem(at: staging) }
        let recorder = DownloadQueueRecorder()
        let runner = HeldConversionRunner(
            infoDocument: DownloadFixture.info(duration: Self.duration),
            postProcessLine: DownloadFixture.postProcessLine,
            fileLine: DownloadFixture.fileLine
        )
        let service = Self.makeService(runner: runner, staging: staging, recorder: recorder)

        _ = try await service.enqueue(urls: [downloadTestURL(DownloadFixture.watchURL)])
        await Self.waitUntil { !Self.conversionFractions(in: recorder).isEmpty }
        let progressFile = try Self.progressFile(inSpawnedArguments: runner.spawnedArguments)
        try Data(Self.block(microseconds: 40_000_000).utf8).write(to: progressFile, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: progressFile.path))

        service.cancelAll()
        runner.releaseTransfer()
        await Self.waitUntil { recorder.terminalCount >= 1 }

        #expect(!FileManager.default.fileExists(atPath: progressFile.path))
    }
}
