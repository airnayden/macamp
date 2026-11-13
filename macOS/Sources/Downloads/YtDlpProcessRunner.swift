// YtDlpProcessRunner — the ONLY file in MacAMP's downloads surface that constructs a
// `Foundation.Process`. `scripts/check-downloader-boundary.sh` exempts this path by
// name and nothing else, so renaming or splitting it re-arms the guard.
//
// ── THE REMIT IS I/O, NOT MEANING ────────────────────────────────────────────
//
// This type launches a tool, buffers its two output pipes into whole lines, and
// reports how it stopped. It does NOT parse a line, map an exit code, or know what
// yt-dlp is — `YtDlpProgressParser` (PlayerCore `Services`) owns all of that. Keeping
// the adapter meaning-free is what lets the entire download state machine be tested
// against `FakeToolProcessRunner` with no process at all.
//
// ── CANCELLATION IS THE STREAM'S, AND IT ENDS WITHOUT `.terminated` ──────────
//
// `ToolProcessRunning` has no `cancel()`. Cancelling the task that consumes the
// returned stream — or simply dropping the iterator — fires the continuation's
// `onTermination` with `.cancelled`, which is where SIGTERM is sent and, after a
// 2-second grace, SIGKILL. That path deliberately does NOT yield a
// ``ToolOutputEvent/terminated(_:)``: the protocol's documented contract is that a
// cancelled stream finishes WITHOUT one, so a consumer reads "finished, no
// termination" as cancellation rather than as success. A SIGTERM'd tool would
// otherwise be indistinguishable from a tool that exited 15.
//
// ── PIPE DISCIPLINE: HANDLERS COME OFF BEFORE THE SIGNAL ─────────────────────
//
// `readabilityHandler` is cleared BEFORE the process is signalled, and again the
// moment it exits (`MCPProcessTransport` precedent). A handler left installed on a
// dead child's pipe keeps a closure — and this object — alive on a dispatch source
// that will never fire again, and is the documented route to a crash on a handle that
// outlives its process. Every teardown path here runs through ``clearReaders()``.
//
// ── ENVIRONMENT ──────────────────────────────────────────────────────────────
//
// The child inherits a SANITIZED copy of this process's environment. yt-dlp's
// argument vector already carries `--ignore-config --no-config-locations`, so this is
// defence in depth for the variables that change behaviour WITHOUT a config file —
// principally the PyInstaller bundle's Python knobs. See
// ``strippedEnvironmentKeys`` for the exact list and what is deliberately kept.
import Darwin
import Foundation
import Services

/// Spawns a bundled download tool and streams its line-oriented output.
final class YtDlpProcessRunner: ToolProcessRunning {
    /// How long a signalled child may take to exit before it is SIGKILLed.
    static let terminationGrace: Duration = .seconds(2)

    /// Environment variables removed from the child's inherited environment.
    ///
    /// `YTDLP_CONFIG_HOME` and `XDG_CONFIG_HOME` relocate the config file yt-dlp
    /// reads; the `YTDLP_NO_*` pair changes which extractors and plugins load; the
    /// `PYTHON*` group is read by the PyInstaller runtime the macOS build is packaged
    /// with and can inject code into the interpreter before yt-dlp's own `main` runs.
    ///
    /// `HOME`, `PATH`, `TMPDIR` and the proxy variables are deliberately KEPT: the
    /// first three are needed for the tool to run at all, and stripping a listener's
    /// `HTTPS_PROXY` would silently break the only network path they have. Config
    /// files under `HOME` are already neutralised by `--ignore-config`.
    static let strippedEnvironmentKeys: Set<String> = [
        "YTDLP_CONFIG_HOME",
        "XDG_CONFIG_HOME",
        "YTDLP_NO_PLUGINS",
        "YTDLP_NO_LAZY_EXTRACTORS",
        "PYTHONPATH",
        "PYTHONHOME",
        "PYTHONSTARTUP",
        "PYTHONEXECUTABLE",
        "PYTHONWARNINGS",
    ]

    private let grace: Duration

    init(terminationGrace: Duration = YtDlpProcessRunner.terminationGrace) {
        grace = terminationGrace
    }

    func spawn(tool: URL, arguments: [String]) async throws -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        try ToolChildProcess(tool: tool, arguments: arguments, grace: grace).start()
    }

    /// `inherited` minus ``strippedEnvironmentKeys``. Pure, so a test can assert the
    /// removal without spawning anything.
    static func sanitizedEnvironment(_ inherited: [String: String]) -> [String: String] {
        inherited.filter { !strippedEnvironmentKeys.contains($0.key) }
    }
}

// MARK: - The child

/// Owns one child process, its two output pipes, and the stream they feed.
///
/// `@unchecked Sendable` with an `NSLock`, because its teardown is reachable from
/// three unsynchronised places at once: the stream's `onTermination` (the consumer's
/// task), `Process.terminationHandler` (a Foundation queue), and the escalation timer.
private final class ToolChildProcess: @unchecked Sendable {
    /// A run of output with no newline longer than this is emitted as one line rather
    /// than buffered further, so a tool that never terminates a line cannot grow this
    /// object's working set without bound.
    private static let maximumLineBytes = 1 << 20

    private let lock = NSLock()
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let grace: Duration

    private var continuation: AsyncThrowingStream<ToolOutputEvent, any Error>.Continuation?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var isCancelled = false
    private var isTornDown = false
    private var escalation: Task<Void, Never>?

    init(tool: URL, arguments: [String], grace: Duration) {
        self.grace = grace
        process.executableURL = tool
        process.arguments = arguments
        process.environment = YtDlpProcessRunner.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        // A tool that reads stdin would otherwise inherit ours and could block the app
        // forever waiting on input no one will type.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
    }

    /// Launches the child and returns the stream of its output.
    ///
    /// The stream is built (and its `onTermination` armed) BEFORE `run()`, so a launch
    /// that throws still leaves a fully-armed teardown behind for the discarded stream.
    func start() throws -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        let stream = AsyncThrowingStream<ToolOutputEvent, any Error> { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            continuation.onTermination = { [self] termination in
                switch termination {
                case .cancelled: cancel()
                default: clearReaders()
                }
            }
        }
        installReaders()
        // `[weak self]`, NOT `[self]`: a strong capture here would be a cycle through
        // `process`, which this object owns, and nothing would ever free either. The
        // optional chain retains `self` for the duration of the call, so the handler
        // body is still safe against a concurrent last release.
        process.terminationHandler = { [weak self] exited in self?.handleExit(of: exited) }
        do {
            try process.run()
        } catch {
            finishLaunchFailure()
            throw DownloadError.toolMissing
        }
        return stream
    }

    // MARK: Reading

    private func installReaders() {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData, isError: false)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData, isError: true)
        }
    }

    /// Appends `data` to the matching buffer and emits every whole line it completed.
    ///
    /// Empty data is EOF: the handler clears itself there, because a handler left
    /// installed past EOF is re-invoked forever with nothing to read.
    private func ingest(_ data: Data, isError: Bool) {
        guard !data.isEmpty else {
            (isError ? errors : output).fileHandleForReading.readabilityHandler = nil
            return
        }
        lock.lock()
        let lines: [String]
        if isError {
            errorBuffer.append(data)
            lines = Self.drainLines(from: &errorBuffer)
        } else {
            outputBuffer.append(data)
            lines = Self.drainLines(from: &outputBuffer)
        }
        let sink = continuation
        lock.unlock()
        // Yielding OUTSIDE the lock: `finish()` re-enters `onTermination` synchronously,
        // and every teardown path takes this same lock.
        for line in lines {
            sink?.yield(isError ? .stderr(line) : .stdout(line))
        }
    }

    /// Splits `buffer` on `\n` and `\r`, leaving any trailing partial line behind.
    ///
    /// Both terminators are honoured because a post-processing step can write carriage
    /// returns even though yt-dlp itself is run with `--newline`; empty segments (the
    /// second half of a `\r\n` pair) are dropped rather than emitted as blank lines.
    private static func drainLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let slice = Data(buffer[buffer.startIndex ..< index])
            buffer.removeSubrange(buffer.startIndex ... index)
            if let line = String(data: slice, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        if buffer.count > maximumLineBytes, let overlong = String(data: buffer, encoding: .utf8) {
            buffer.removeAll(keepingCapacity: false)
            lines.append(overlong)
        }
        return lines
    }

    // MARK: Teardown

    private func clearReaders() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }

    /// The child exited on its own. Drains what is left in the pipes, reports the
    /// termination (unless this was a cancellation) and finishes the stream.
    private func handleExit(of exited: Process) {
        lock.lock()
        guard !isTornDown else { return lock.unlock() }
        isTornDown = true
        let cancelled = isCancelled
        let sink = continuation
        // Releases the escalation task's STRONG `self`, and stops it SIGKILLing a pid
        // Foundation is about to reap.
        escalation?.cancel()
        escalation = nil
        // Drops this object's edge to the continuation whose `onTermination` closure
        // holds it back, so `finish()` below leaves nothing retaining either side.
        continuation = nil
        lock.unlock()

        clearReaders()
        let trailing = drainRemainder()
        for event in trailing {
            sink?.yield(event)
        }
        if !cancelled {
            sink?.yield(.terminated(Self.termination(of: exited)))
        }
        sink?.finish()
    }

    /// Reads both pipes to EOF and turns everything still buffered into events.
    ///
    /// The final chunk routinely has no trailing newline, so the leftovers are emitted
    /// as one last line each rather than discarded.
    private func drainRemainder() -> [ToolOutputEvent] {
        let restOut = (try? output.fileHandleForReading.readToEnd()) ?? nil
        let restErr = (try? errors.fileHandleForReading.readToEnd()) ?? nil
        lock.lock()
        defer { lock.unlock() }
        if let restOut { outputBuffer.append(restOut) }
        if let restErr { errorBuffer.append(restErr) }
        var events = Self.drainLines(from: &outputBuffer).map(ToolOutputEvent.stdout)
        events += Self.drainLines(from: &errorBuffer).map(ToolOutputEvent.stderr)
        events += Self.flush(&outputBuffer).map(ToolOutputEvent.stdout)
        events += Self.flush(&errorBuffer).map(ToolOutputEvent.stderr)
        return events
    }

    /// Empties `buffer` into at most one final, newline-less line.
    private static func flush(_ buffer: inout Data) -> [String] {
        defer { buffer.removeAll(keepingCapacity: false) }
        guard let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty else { return [] }
        return [tail]
    }

    private static func termination(of exited: Process) -> ProcessTermination {
        switch exited.terminationReason {
        case .uncaughtSignal:
            ProcessTermination(status: exited.terminationStatus, reason: .uncaughtSignal)
        default:
            ProcessTermination(status: exited.terminationStatus, reason: .normalExit)
        }
    }

    /// The consumer stopped consuming: SIGTERM now, SIGKILL after the grace period.
    ///
    /// Handlers come off BEFORE the signal (see the file header), and the cancellation
    /// flag is what suppresses the `.terminated` event `handleExit` would otherwise
    /// yield once the child dies.
    private func cancel() {
        lock.lock()
        guard !isTornDown else { return lock.unlock() }
        isCancelled = true
        lock.unlock()

        clearReaders()
        guard process.isRunning else { return }
        process.terminate()
        scheduleEscalation()
    }

    /// Holds `self` STRONGLY, and is the only place that does after cancellation.
    ///
    /// By the time this runs the stream has already released its `onTermination`
    /// closure — the reference the whole cancel path arrived on — and the termination
    /// handler is weak. A `[weak self]` escalation would therefore find nothing and
    /// silently never send SIGKILL, which is precisely the case this exists for. The
    /// strong capture lasts at most one grace period, and `handleExit` cancels the task
    /// the moment the child dies on its own.
    private func scheduleEscalation() {
        let task = Task.detached(priority: .utility) { [self, grace] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            forceKill()
        }
        lock.lock()
        if isTornDown {
            task.cancel()
        } else {
            escalation = task
        }
        lock.unlock()
    }

    /// SIGKILL, which `Process` exposes no API for.
    ///
    /// `isTornDown` is checked under the lock so the pid cannot be read after
    /// Foundation has reaped it — the window where the number could name a different,
    /// unrelated process.
    private func forceKill() {
        lock.lock()
        let pid = (isTornDown || !process.isRunning) ? 0 : process.processIdentifier
        lock.unlock()
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    /// `run()` threw, so no `terminationHandler` will ever fire. Finishes the stream
    /// the caller is about to discard, and takes the handlers back off.
    private func finishLaunchFailure() {
        lock.lock()
        isTornDown = true
        let sink = continuation
        continuation = nil
        lock.unlock()
        clearReaders()
        sink?.finish()
    }
}
