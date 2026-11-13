// `FakeToolProcessRunner` drives every shape a spawned tool can end in — clean exit,
// the engine's non-zero exit ladder, a SIGNAL kill (the real cancellation path), and a
// stream that ends with no termination at all — and proves each one reaches a consumer
// as a typed ``DownloadError``.
//
// The consumer below drives the PRODUCTION parser and map (`YtDlpProgressParser`), not
// a stand-in: the test-local placeholder todo 1 left here was deleted the moment the
// real map landed, so there is exactly one termination contract in the repo and this
// suite is a genuine end-to-end proof of it over the process seam.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

/// Drains a scripted spawn the way the download driver will: sentinel lines through
/// ``YtDlpProgressParser/event(from:)``, stderr kept as diagnostics, and the
/// termination run through the production map.
func consumeDownload(
    runner: any ToolProcessRunning,
    tool: URL,
    arguments: [String] = [],
    cancellationRequested: Bool = false
) async throws -> DownloadOutcome {
    var destination: String?
    var lastError: String?
    var termination: ProcessTermination?
    for try await event in try await runner.spawn(tool: tool, arguments: arguments) {
        switch event {
        case let .stdout(line):
            if case let .destination(path)? = YtDlpProgressParser.event(from: line) { destination = path }
        case let .stderr(line): lastError = line
        case let .terminated(value): termination = value
        }
    }
    // A stream that ends without a termination event was cancelled — never success.
    guard let termination else { return .failed(.cancelled) }
    return YtDlpProgressParser.outcome(
        of: termination,
        filePath: destination,
        lastErrorLine: lastError,
        cancellationRequested: cancellationRequested
    )
}

/// One row of the exit-code ladder.
struct ExitLadderCase: CustomStringConvertible {
    let name: String
    let status: Int32
    let expected: DownloadError

    var description: String {
        name
    }
}

@Suite("Tool process seam")
struct ToolProcessSeamTests {
    static let tool = URL(fileURLWithPath: "/tmp/macamp-fake-tools/yt-dlp")
    static let destination = "/Users/test/Music/MacAMP Downloads/Song.m4a"
    /// What the engine actually prints for the finished file — the only line the
    /// consumer reads a destination from.
    static let fileLine = "MACAMP-FILE|/Users/test/Music/MacAMP Downloads/Song.m4a"

    static let exitLadder: [ExitLadderCase] = [
        ExitLadderCase(name: "exit 1 → download failed", status: 1, expected: .downloadFailed(detail: "boom")),
        ExitLadderCase(name: "exit 2 → invalid arguments", status: 2, expected: .invalidArguments),
        ExitLadderCase(name: "exit 100 → restart required", status: 100, expected: .engineRestartRequired),
        ExitLadderCase(name: "exit 101 → cancelled by engine", status: 101, expected: .cancelledByEngine),
        ExitLadderCase(name: "exit 137 → unknown", status: 137, expected: .unknown(code: 137)),
    ]

    @Test("a clean run streams its destination and completes")
    func cleanRunCompletes() async throws {
        let runner = FakeToolProcessRunner(scripts: [.success(stdout: [Self.fileLine])])
        let outcome = try await consumeDownload(runner: runner, tool: Self.tool)
        #expect(outcome == .completed(filePath: Self.destination))
        #expect(runner.spawnCount == 1)
    }

    /// The plan's failure QA scenario: a scripted non-zero exit must surface as a
    /// TYPED `DownloadError` in a consumer, carrying the engine's own diagnostics.
    @Test("a scripted non-zero exit surfaces as a typed error", arguments: exitLadder)
    func exitCodesMapToTypedErrors(testCase: ExitLadderCase) async throws {
        let runner = FakeToolProcessRunner(scripts: [.exit(status: testCase.status, stderr: ["boom"])])
        let outcome = try await consumeDownload(runner: runner, tool: Self.tool)
        #expect(outcome == .failed(testCase.expected))
    }

    @Test("engine diagnostics ride the typed error, not the localized message")
    func diagnosticsReachTheConsumer() async throws {
        let detail = "ERROR: unable to download video data: HTTP Error 403: Forbidden"
        let runner = FakeToolProcessRunner(scripts: [.exit(status: 1, stderr: [detail])])
        let outcome = try await consumeDownload(runner: runner, tool: Self.tool)
        #expect(outcome == .failed(.downloadFailed(detail: detail)))
    }

    /// SIGTERM→SIGKILL is how a download is really cancelled, so a REQUESTED signal
    /// termination must be representable and must NOT read as a fault.
    @Test("a requested signal termination reads as cancellation", arguments: [SIGTERM, SIGKILL, SIGINT])
    func signalTerminationsAreCancellations(signal: Int32) async throws {
        let runner = FakeToolProcessRunner(scripts: [.signal(signal, stdout: [Self.fileLine])])
        let outcome = try await consumeDownload(
            runner: runner,
            tool: Self.tool,
            cancellationRequested: true
        )
        #expect(outcome == .failed(.cancelled))
    }

    /// The same shape with nobody asking for it is a FAULT — the engine crashed.
    @Test("an unrequested signal termination reads as a failure")
    func unrequestedSignalIsFailure() async throws {
        let runner = FakeToolProcessRunner(scripts: [.signal(SIGKILL)])
        let outcome = try await consumeDownload(runner: runner, tool: Self.tool)
        #expect(outcome == .failed(.downloadFailed(detail: "terminated by signal \(SIGKILL)")))
    }

    @Test("a stream that ends without a termination event is a cancellation")
    func missingTerminationIsCancellation() async throws {
        let runner = FakeToolProcessRunner(scripts: [.cancelled(stdout: ["[download]  42.0%"])])
        let outcome = try await consumeDownload(runner: runner, tool: Self.tool)
        #expect(outcome == .failed(.cancelled))
    }

    @Test("a launch failure throws instead of yielding a stream")
    func launchFailureThrows() async {
        let runner = FakeToolProcessRunner(
            scripts: [ToolProcessScript(launchError: DownloadError.toolMissing)]
        )
        await #expect(throws: DownloadError.toolMissing) {
            _ = try await consumeDownload(runner: runner, tool: Self.tool)
        }
    }

    @Test("stdout and stderr arrive as distinct, ordered line events")
    func streamsAreDistinguishable() async throws {
        let script = ToolProcessScript(
            lines: [.stdout("[info] one"), .stderr("WARNING: two"), .stdout("[info] three")],
            termination: .success
        )
        let runner = FakeToolProcessRunner(scripts: [script])
        var events: [ToolOutputEvent] = []
        for try await event in try await runner.spawn(tool: Self.tool, arguments: []) {
            events.append(event)
        }
        #expect(events == script.lines + [.terminated(.success)])
    }

    @Test("the tool and its argument vector are recorded verbatim")
    func spawnsAreRecorded() async throws {
        let runner = FakeToolProcessRunner()
        let arguments = ["--newline", "--print", "after_move:filepath", "https://youtu.be/dQw4w9WgXcQ"]
        for try await _ in try await runner.spawn(tool: Self.tool, arguments: arguments) {}

        #expect(runner.spawnRequests == [ToolSpawnRequest(tool: Self.tool, arguments: arguments)])
        #expect(runner.lastSpawn?.arguments == arguments)
    }

    @Test("scripts are consumed in order, then the default answers")
    func scriptsAreConsumedInOrder() async throws {
        let runner = FakeToolProcessRunner(scripts: [.exit(status: 2), .success(stdout: [Self.fileLine])])
        runner.enqueue(.exit(status: 100))

        let first = try await consumeDownload(runner: runner, tool: Self.tool)
        let second = try await consumeDownload(runner: runner, tool: Self.tool)
        let third = try await consumeDownload(runner: runner, tool: Self.tool)
        let fourth = try await consumeDownload(runner: runner, tool: Self.tool)

        #expect(first == .failed(.invalidArguments))
        #expect(second == .completed(filePath: Self.destination))
        #expect(third == .failed(.engineRestartRequired))
        // The default script exits 0 having printed nothing — a clean run that moved no
        // file, which is exactly the already-downloaded shape.
        #expect(fourth == .failed(.alreadyDownloaded))
        #expect(runner.spawnCount == 4)
    }

    @Test("only a zero-status normal exit counts as success")
    func successIsNarrow() {
        #expect(ProcessTermination.success.isSuccess)
        #expect(!ProcessTermination(status: 1, reason: .normalExit).isSuccess)
        #expect(!ProcessTermination(status: 0, reason: .uncaughtSignal).isSuccess)
        #expect(!ProcessTermination(status: SIGTERM, reason: .uncaughtSignal).isSuccess)
    }

    @Test("termination reason raw values are stable", arguments: ProcessTermination.Reason.allCases)
    func reasonRawValues(reason: ProcessTermination.Reason) {
        #expect(["normalExit", "uncaughtSignal"].contains(reason.rawValue))
    }
}
