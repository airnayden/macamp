// FakeToolProcessRunner — a deterministic, process-free ``ToolProcessRunning`` double.
//
// Scripts what a spawned tool "prints" and how it ends, so download parsing and the
// engine-termination map are testable with zero `Process`, zero I/O and zero timing.
// Every termination shape is drivable: a clean exit, a non-zero exit code (yt-dlp's
// 1/2/100/101), a SIGNAL termination (the real cancellation path — SIGTERM→SIGKILL),
// and the cancelled shape where the stream ends WITHOUT a termination event at all.
//
// Style mirrors `FakeStemSeparator`: a `@unchecked Sendable` final class guarded by an
// `NSLock` (the protocol is `Sendable`, not `@MainActor`).
import Foundation
import Services

/// What a single scripted spawn emits and how it ends.
public struct ToolProcessScript: Sendable, Equatable {
    /// The stdout/stderr lines emitted, in order. A ``ToolOutputEvent/terminated(_:)``
    /// here is ignored — termination is ``termination``'s job.
    public var lines: [ToolOutputEvent]
    /// How the process ended, or `nil` to model CANCELLATION: the stream finishes
    /// without a termination event, exactly as a killed child does.
    public var termination: ProcessTermination?
    /// When set, ``ToolProcessRunning/spawn(tool:arguments:)`` throws this instead of
    /// returning a stream — the "could not be launched at all" path.
    public var launchError: (any Error)?

    public init(
        lines: [ToolOutputEvent] = [],
        termination: ProcessTermination? = .success,
        launchError: (any Error)? = nil
    ) {
        self.lines = lines
        self.termination = termination
        self.launchError = launchError
    }

    public static func == (lhs: ToolProcessScript, rhs: ToolProcessScript) -> Bool {
        lhs.lines == rhs.lines
            && lhs.termination == rhs.termination
            && (lhs.launchError == nil) == (rhs.launchError == nil)
    }

    /// A clean run: the given stdout lines, then exit 0.
    public static func success(stdout: [String] = []) -> ToolProcessScript {
        ToolProcessScript(lines: stdout.map(ToolOutputEvent.stdout), termination: .success)
    }

    /// A normal exit with a non-zero code — yt-dlp's `1`/`2`/`100`/`101` ladder.
    public static func exit(status: Int32, stderr: [String] = []) -> ToolProcessScript {
        ToolProcessScript(
            lines: stderr.map(ToolOutputEvent.stderr),
            termination: ProcessTermination(status: status, reason: .normalExit)
        )
    }

    /// A signal termination — the real cancellation path (SIGTERM = 15, SIGKILL = 9).
    public static func signal(_ signal: Int32, stdout: [String] = []) -> ToolProcessScript {
        ToolProcessScript(
            lines: stdout.map(ToolOutputEvent.stdout),
            termination: ProcessTermination(status: signal, reason: .uncaughtSignal)
        )
    }

    /// A cancelled run: some output, then the stream simply ends with no termination.
    public static func cancelled(stdout: [String] = []) -> ToolProcessScript {
        ToolProcessScript(lines: stdout.map(ToolOutputEvent.stdout), termination: nil)
    }
}

/// One recorded spawn. A struct, not a tuple, so it stays readable as it grows.
public struct ToolSpawnRequest: Sendable, Equatable, Hashable {
    public let tool: URL
    public let arguments: [String]

    public init(tool: URL, arguments: [String]) {
        self.tool = tool
        self.arguments = arguments
    }
}

/// A canned ``ToolProcessRunning`` for hermetic tests and previews.
public final class FakeToolProcessRunner: ToolProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [ToolProcessScript]
    private var defaultScript: ToolProcessScript
    private var recorded: [ToolSpawnRequest] = []
    private var sideEffect: (@Sendable (ToolSpawnRequest) -> Void)?

    /// - Parameters:
    ///   - scripts: Consumed in order, one per spawn. When exhausted, `defaultScript`
    ///     answers every further spawn.
    ///   - defaultScript: The fallback response (a clean, silent exit 0).
    ///   - onSpawn: A FILESYSTEM EFFECT to perform before the scripted output is
    ///     yielded. Scripting stdout is enough for a tool that only reports (`--version`,
    ///     `codesign -dv`), but not for one whose whole purpose is to leave something on
    ///     disk — `ditto -x -k` expanding an engine archive is exactly that, and a double
    ///     that returned exit 0 without producing a tree would prove the caller handles a
    ///     successful extraction while never testing one.
    public init(
        scripts: [ToolProcessScript] = [],
        defaultScript: ToolProcessScript = ToolProcessScript(),
        onSpawn: (@Sendable (ToolSpawnRequest) -> Void)? = nil
    ) {
        self.scripts = scripts
        self.defaultScript = defaultScript
        sideEffect = onSpawn
    }

    public func spawn(
        tool: URL,
        arguments: [String]
    ) async throws -> AsyncThrowingStream<ToolOutputEvent, any Error> {
        let request = ToolSpawnRequest(tool: tool, arguments: arguments)
        let (script, effect) = lock.withLock {
            recorded.append(request)
            return (scripts.isEmpty ? defaultScript : scripts.removeFirst(), sideEffect)
        }
        if let launchError = script.launchError { throw launchError }
        effect?(request)
        return AsyncThrowingStream { continuation in
            for line in script.lines where !line.isTermination {
                continuation.yield(line)
            }
            if let termination = script.termination {
                continuation.yield(.terminated(termination))
            }
            continuation.finish()
        }
    }

    // MARK: - Test helpers

    /// Every spawn this double received, in order.
    public var spawnRequests: [ToolSpawnRequest] {
        lock.withLock { recorded }
    }

    /// How many spawns this double received.
    public var spawnCount: Int {
        lock.withLock { recorded.count }
    }

    /// The most recent spawn, when any.
    public var lastSpawn: ToolSpawnRequest? {
        lock.withLock { recorded.last }
    }

    /// Appends a script to the queue consumed by subsequent spawns.
    public func enqueue(_ script: ToolProcessScript) {
        lock.withLock { scripts.append(script) }
    }

    /// Replaces the fallback used once the scripted queue is exhausted.
    public func setDefaultScript(_ script: ToolProcessScript) {
        lock.withLock { defaultScript = script }
    }

    /// Replaces the filesystem effect performed on every spawn.
    public func setOnSpawn(_ onSpawn: (@Sendable (ToolSpawnRequest) -> Void)?) {
        lock.withLock { sideEffect = onSpawn }
    }
}

private extension ToolOutputEvent {
    var isTermination: Bool {
        if case .terminated = self { return true }
        return false
    }
}
