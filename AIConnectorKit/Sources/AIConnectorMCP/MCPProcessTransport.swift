// MCPProcessTransport — the ONLY file in MacAMP's AI surface that constructs a
// `Foundation.Process`.
//
// ── THE REMIT IS THE CHILD, NOT THE PROTOCOL ─────────────────────────────────
//
// The pinned SDK already implements stdio framing, and `StdioTransport`'s
// descriptors are PARAMETER DEFAULTS rather than hardcoded FD 0/1 — so a caller
// may spawn its own child and hand over that child's pipe ends. What the SDK
// deliberately does not do is spawn or supervise a process. This type is that
// half: launch, pipe ownership, stderr drain, termination. It conforms to
// `Transport` so `MCPClientManager` sees one uniform seam for HTTP and stdio.
//
// ── FD OWNERSHIP: WE DUP, AND WE ALONE CLOSE ─────────────────────────────────
//
// The spike flagged a suspected DOUBLE-CLOSE (a `Pipe`'s `FileHandle` closes its
// own descriptor, and `StdioTransport.disconnect()` was assumed to close what it
// was given). Reading the pinned 0.12.1 source settles it: `StdioTransport` has NO
// `deinit`, and its `disconnect()` only flips `isConnected` and finishes the
// message stream. It never closes a descriptor. So the double-close is not the
// live hazard.
//
// The live hazard is the MIRROR IMAGE, and it is worse because it is silent: the
// `Pipe`'s `FileHandle` closes the descriptor on ITS OWN schedule, while
// `StdioTransport.readLoop` holds nothing but the raw `Int32`. Once that number is
// closed the kernel is free to hand it to the next `open()` anywhere in the
// process, and the read loop would then be reading an unrelated file.
//
// DECISION: `dup(2)` both parent-side ends and hand the DUPLICATES to
// `StdioTransport`. The duplicate's lifetime is owned by exactly one object —
// ``ChildProcess`` — and closed exactly once, under a lock, AFTER the SDK
// transport has been disconnected. This also stays correct if a future SDK version
// does start closing what it is given: closing a dup leaves the `Pipe`'s original
// untouched. Cost: `dup` shares the open file description, so the `O_NONBLOCK`
// that `StdioTransport.connect()` sets is visible on the `Pipe`'s handle too —
// harmless here, because those two handles are never used for I/O again.
//
// ── SECRETS ──────────────────────────────────────────────────────────────────
//
// The environment dictionary this type is handed may contain credential VALUES.
// Nothing here logs it, stores it beyond the spawn, or copies it into an error.
// Stderr is drained and DISCARDED for the same reason: a child that echoes its own
// configuration back must not be able to put a token into MacAMP's diagnostics.
import Foundation
import Logging
import MCP
import System

/// Runs an MCP server as a child process and speaks stdio to it.
public actor MCPProcessTransport: Transport {
    public nonisolated let logger: Logger

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]

    private let inbound: AsyncThrowingStream<Data, any Swift.Error>
    private let inboundContinuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation

    private var child: ChildProcess?
    private var stdio: StdioTransport?
    private var pump: Task<Void, Never>?

    /// - Parameters:
    ///   - command: An absolute path, or a bare name resolved through `PATH`.
    ///   - arguments: Argument vector, excluding the command itself.
    ///   - environment: Variables to ADD to the inherited environment. This is
    ///     where a resolved secret arrives; see the file header.
    public init(
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        logger: Logger? = nil
    ) {
        let resolved = Self.resolve(command: command, arguments: arguments)
        executableURL = resolved.url
        self.arguments = resolved.arguments
        self.environment = environment
        self.logger = logger ?? Logger(label: "macamp.mcp.transport.process")

        var handoff: AsyncThrowingStream<Data, any Swift.Error>.Continuation!
        inbound = AsyncThrowingStream { handoff = $0 }
        inboundContinuation = handoff
    }

    /// The descriptor pair to hand a `StdioTransport`, for a command that is a
    /// path, or `/usr/bin/env` for one that is a bare name.
    ///
    /// `env` rather than a hand-rolled `PATH` walk: a bare `npx` is what a
    /// listener will type, and resolution rules (`PATHEXT`-free, but symlinks,
    /// `PATH` order and executability all matter) are the shell's job, not ours.
    private static func resolve(command: String, arguments: [String]) -> (url: URL, arguments: [String]) {
        guard command.contains("/") else {
            return (URL(fileURLWithPath: "/usr/bin/env"), [command] + arguments)
        }
        return (URL(fileURLWithPath: command), arguments)
    }

    /// Whether the child is alive. Exists so a test can prove termination.
    public var isChildRunning: Bool {
        child?.isRunning ?? false
    }

    // MARK: - Transport

    public func connect() async throws {
        guard child == nil else { return }
        let spawned = ChildProcess(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        )
        let ends = try spawned.launch()
        let transport = StdioTransport(input: ends.input, output: ends.output, logger: logger)
        do {
            try await transport.connect()
        } catch {
            spawned.terminate()
            throw error
        }
        child = spawned
        stdio = transport
        await startPump(from: transport.receive())
    }

    /// Disconnects the SDK transport FIRST, then terminates the child and closes
    /// the duplicated descriptors — the ordering the file header's dup decision
    /// depends on.
    public func disconnect() async {
        pump?.cancel()
        pump = nil
        if let stdio { await stdio.disconnect() }
        stdio = nil
        inboundContinuation.finish()
        child?.terminate()
        child = nil
    }

    public func send(_ data: Data) async throws {
        guard let stdio else { throw MCPError.connectionClosed }
        try await stdio.send(data)
    }

    public nonisolated func receive() -> AsyncThrowingStream<Data, any Swift.Error> {
        inbound
    }

    /// Forwards the SDK transport's stream onto this transport's own.
    ///
    /// Captures the stream and the continuation, never `self`: an actor whose only
    /// remaining reference was a background pump would never deallocate, and this
    /// one owns a running program.
    private func startPump(from stream: AsyncThrowingStream<Data, any Swift.Error>) {
        pump = Task { [continuation = inboundContinuation] in
            do {
                for try await data in stream {
                    continuation.yield(data)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

// MARK: - The child

/// Owns one child process, its three pipes, and the two duplicated descriptors
/// handed to the SDK's stdio transport.
///
/// A class rather than actor state so its `deinit` can terminate a child that
/// nobody disconnected — an abandoned MCP server must not outlive the app's
/// interest in it. `@unchecked Sendable` with an `NSLock`, because `terminate()`
/// is reachable from both an actor and a deinit and must be idempotent under both.
private final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let outgoing = Pipe()
    private let incoming = Pipe()
    private let diagnostics = Pipe()
    private var duplicated: [Int32] = []
    private var isTornDown = false

    init(executableURL: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = outgoing
        process.standardOutput = incoming
        process.standardError = diagnostics
    }

    deinit {
        terminate(waitForExit: false)
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isTornDown == false && process.isRunning
    }

    /// Launches the child and returns the descriptors to speak to it on.
    func launch() throws -> (input: FileDescriptor, output: FileDescriptor) {
        do {
            try process.run()
        } catch {
            throw MCPClientFailure.unreachable(
                underlying: MCPClientFailure.DiagnosticToken.processLaunchFailed
            )
        }
        drainDiagnostics()
        let readEnd = dup(incoming.fileHandleForReading.fileDescriptor)
        let writeEnd = dup(outgoing.fileHandleForWriting.fileDescriptor)
        guard readEnd >= 0, writeEnd >= 0 else {
            if readEnd >= 0 { close(readEnd) }
            if writeEnd >= 0 { close(writeEnd) }
            terminate()
            throw MCPClientFailure.unreachable(
                underlying: MCPClientFailure.DiagnosticToken.processLaunchFailed
            )
        }
        lock.lock()
        duplicated = [readEnd, writeEnd]
        lock.unlock()
        return (FileDescriptor(rawValue: readEnd), FileDescriptor(rawValue: writeEnd))
    }

    /// Reads and DISCARDS the child's stderr, so a chatty server cannot fill the
    /// pipe buffer and block on a write forever.
    ///
    /// The handler clears itself at EOF: `availableData` returns empty from then
    /// on, and a handler that stayed installed would spin. Nothing is captured, so
    /// there is no retain cycle and nowhere for a leaked credential to land.
    private func drainDiagnostics() {
        diagnostics.fileHandleForReading.readabilityHandler = { source in
            if source.availableData.isEmpty { source.readabilityHandler = nil }
        }
    }

    /// Stops the child and closes the duplicates. Safe to call more than once, and
    /// from a `deinit`.
    func terminate(waitForExit: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard isTornDown == false else { return }
        isTornDown = true
        diagnostics.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let reap: @Sendable () -> Void = { [process] in
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
                while process.isRunning, ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            if waitForExit {
                reap()
            } else {
                // Destruction can run on the main thread; only explicit
                // disconnect waits for the child to be reaped.
                DispatchQueue.global(qos: .utility).async(execute: reap)
            }
        }
        for descriptor in duplicated {
            close(descriptor)
        }
        duplicated = []
    }
}
