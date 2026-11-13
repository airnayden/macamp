// DownloadProcessRunnerTests — the two claims about spawning that cannot be made
// against a fake, plus the quit-path wiring that cancels the queue.
//
// This suite lives in the macOS app test target, not the PlayerCore package, for the
// same reason `TerminationFlushTests` does: `YtDlpProcessRunner` is the shell's only
// `Foundation.Process` file (`Process` does not exist on iOS at all), and
// `AppEnvironment` is a shell type. `swift test` cannot reach either.
//
// ── WHY A REAL CHILD, AND WHY /bin/sh ────────────────────────────────────────
//
// `FakeToolProcessRunner` already proves every SHAPE a spawn can end in, and
// `ToolProcessSeamTests` drives the production parser over it. What a fake structurally
// cannot prove is that a signal was actually delivered to a running program. So the two
// escalation tests spawn `/bin/sh` — present on every macOS machine and every CI
// runner — and distinguish SIGTERM from SIGKILL by the only means that exists: a child
// that IGNORES SIGTERM can only be stopped by SIGKILL.
//
//   escalation:  `trap '' TERM` + short grace  -> it dies  => SIGKILL was sent
//   no escalation: no trap      + long  grace  -> it dies  => SIGTERM was sent FIRST
//
// Neither test alone means much; together they pin the ladder, and each fails for a
// different, diagnosable reason.
//
// ── WHY THESE POLL ───────────────────────────────────────────────────────────
//
// A process's death is observed through the kernel, which offers this test no
// completion signal to fence on: `kill(pid, 0)` answering ESRCH is the only evidence
// there is. Every poll therefore runs against a generous deadline and returns as soon
// as the condition holds, so a loaded machine costs latency rather than a failure.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Download process runner")
struct DownloadProcessRunnerTests {
    /// A grace far shorter than production's 2 s so the escalation test is quick, and
    /// far longer than a spawn so it cannot fire before SIGTERM has been tried.
    static let shortGrace: Duration = .milliseconds(300)
    /// Longer than any assertion below waits, so a test that observes a death inside
    /// its own deadline proves SIGTERM did it — escalation could not have run yet.
    static let unreachableGrace: Duration = .seconds(120)
    static let shell = URL(fileURLWithPath: "/bin/sh")

    // MARK: The I/O adapter

    @Test("stdout and stderr arrive as whole lines, ending in one termination event")
    func theAdapterSplitsLinesAndReportsTheExit() async throws {
        let runner = YtDlpProcessRunner()
        let script = "printf 'first\\nsecond\\n'; printf 'boom\\n' 1>&2; exit 3"

        var out: [String] = []
        var err: [String] = []
        var termination: ProcessTermination?
        for try await event in try await runner.spawn(tool: Self.shell, arguments: ["-c", script]) {
            switch event {
            case let .stdout(line): out.append(line)
            case let .stderr(line): err.append(line)
            case let .terminated(value): termination = value
            }
        }

        #expect(out == ["first", "second"])
        #expect(err == ["boom"])
        #expect(termination == ProcessTermination(status: 3, reason: .normalExit))
    }

    /// A tool's last write routinely has no trailing newline. Dropping it would lose
    /// the `MACAMP-FILE|` line that names the finished download.
    @Test("a final line with no trailing newline is still delivered")
    func theTrailingPartialLineIsFlushed() async throws {
        let runner = YtDlpProcessRunner()

        var out: [String] = []
        for try await event in try await runner.spawn(
            tool: Self.shell,
            arguments: ["-c", "printf 'no-newline-here'"]
        ) where event.isStdout {
            if case let .stdout(line) = event { out.append(line) }
        }

        #expect(out == ["no-newline-here"])
    }

    @Test("a missing executable throws toolMissing rather than streaming")
    func anUnlaunchableToolThrows() async throws {
        let runner = YtDlpProcessRunner()
        let absent = URL(fileURLWithPath: "/nonexistent/macamp/yt-dlp_macos")

        await #expect(throws: DownloadError.toolMissing) {
            _ = try await runner.spawn(tool: absent, arguments: [])
        }
    }

    // MARK: Cancellation

    /// Todo 1's contract, over the production runner: a cancelled stream ends WITHOUT
    /// a `.terminated` event, so "finished with no termination" reads as cancellation
    /// and never as success. A SIGTERM'd tool would otherwise be indistinguishable
    /// from one that exited 15.
    @Test("a cancelled stream finishes without a termination event")
    func cancellationYieldsNoTermination() async throws {
        let runner = YtDlpProcessRunner(terminationGrace: Self.shortGrace)
        let observed = TerminationWitness()
        let consumer = Task {
            for try await event in try await runner.spawn(
                tool: Self.shell,
                arguments: ["-c", "echo $$; while :; do sleep 0.2; done"]
            ) {
                if case .terminated = event { observed.sawTermination() }
                if case .stdout = event { observed.sawFirstLine() }
            }
        }

        try await Self.poll(deadline: .seconds(10)) { observed.hasFirstLine }
        consumer.cancel()
        _ = await consumer.result

        #expect(!observed.hasTermination)
    }

    /// SIGTERM is IGNORED by the child and the grace is short, so the only thing that
    /// can end it is the SIGKILL escalation.
    @Test("a child that ignores SIGTERM is SIGKILLed after the grace period")
    func escalationKillsATermProofChild() async throws {
        let pid = try await Self.runAndCancel(
            grace: Self.shortGrace,
            script: "trap '' TERM; echo $$; while :; do sleep 0.2; done"
        )

        #expect(try await Self.poll(deadline: .seconds(15)) { !Self.isAlive(pid) })
    }

    /// The negative control for the test above: the same child WITHOUT the trap, and a
    /// grace so long the escalation cannot have run. It still dies, so the first signal
    /// really is SIGTERM — the escalation is a backstop, not the mechanism.
    @Test("SIGTERM alone stops a child that honours it, long before any escalation")
    func termAloneStopsACooperativeChild() async throws {
        let pid = try await Self.runAndCancel(
            grace: Self.unreachableGrace,
            script: "echo $$; while :; do sleep 0.2; done"
        )

        #expect(try await Self.poll(deadline: .seconds(15)) { !Self.isAlive(pid) })
    }

    // MARK: Environment

    @Test("every config-relevant variable is stripped from the child's environment")
    func theChildEnvironmentIsSanitized() {
        var inherited = ["PATH": "/usr/bin", "HOME": "/Users/listener", "HTTPS_PROXY": "http://proxy:3128"]
        for key in YtDlpProcessRunner.strippedEnvironmentKeys {
            inherited[key] = "hostile"
        }

        let sanitized = YtDlpProcessRunner.sanitizedEnvironment(inherited)

        for key in YtDlpProcessRunner.strippedEnvironmentKeys {
            #expect(sanitized[key] == nil, "\(key) must not reach the child")
        }
        // Kept on purpose: the tool cannot run without the first two, and stripping a
        // listener's proxy would break the only network path they have.
        #expect(sanitized["PATH"] == "/usr/bin")
        #expect(sanitized["HOME"] == "/Users/listener")
        #expect(sanitized["HTTPS_PROXY"] == "http://proxy:3128")
    }

    @Test("the stripped list names the yt-dlp config and PyInstaller knobs")
    func theStrippedListIsTheDocumentedOne() {
        let stripped = YtDlpProcessRunner.strippedEnvironmentKeys

        #expect(stripped.contains("YTDLP_CONFIG_HOME"))
        #expect(stripped.contains("XDG_CONFIG_HOME"))
        #expect(stripped.contains("PYTHONPATH"))
        #expect(stripped.contains("PYTHONHOME"))
        // HOME is NOT stripped — `--ignore-config` neutralises the files under it, and
        // removing it would break the tool outright.
        #expect(!stripped.contains("HOME"))
    }

    // MARK: Fixtures

    /// Spawns `script`, waits for it to report its own pid, then cancels the consuming
    /// task — the only cancellation surface `ToolProcessRunning` has.
    static func runAndCancel(grace: Duration, script: String) async throws -> pid_t {
        let runner = YtDlpProcessRunner(terminationGrace: grace)
        let witness = TerminationWitness()
        let consumer = Task {
            for try await event in try await runner.spawn(tool: shell, arguments: ["-c", script]) {
                if case let .stdout(line) = event, let pid = pid_t(line) { witness.sawPid(pid) }
            }
        }
        try await poll(deadline: .seconds(10)) { witness.pid != nil }
        guard let pid = witness.pid else {
            throw RunnerFixtureError.childNeverReportedItsPid
        }
        consumer.cancel()
        return pid
    }

    /// Whether `pid` still names a live (or not-yet-reaped) process.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Returns as soon as `condition` holds, or `false` at the deadline.
    @discardableResult
    static func poll(deadline: Duration, condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let expiry = clock.now.advanced(by: deadline)
        while clock.now < expiry {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}

enum RunnerFixtureError: Error {
    case childNeverReportedItsPid
}

/// Records what a spawn produced, from the consuming task.
///
/// Lock-guarded and `@unchecked Sendable`: it is written inside a detached consumer and
/// read from the test body, which are different isolation domains.
final class TerminationWitness: @unchecked Sendable {
    private let lock = NSLock()
    private var terminationSeen = false
    private var firstLineSeen = false
    private var reportedPid: pid_t?

    func sawTermination() {
        lock.withLock { terminationSeen = true }
    }

    func sawFirstLine() {
        lock.withLock { firstLineSeen = true }
    }

    func sawPid(_ value: pid_t) {
        lock.withLock { reportedPid = value; firstLineSeen = true }
    }

    var hasTermination: Bool {
        lock.withLock { terminationSeen }
    }

    var hasFirstLine: Bool {
        lock.withLock { firstLineSeen }
    }

    var pid: pid_t? {
        lock.withLock { reportedPid }
    }
}

private extension ToolOutputEvent {
    var isStdout: Bool {
        if case .stdout = self { return true }
        return false
    }
}
