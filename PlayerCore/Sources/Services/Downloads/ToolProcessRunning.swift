// ToolProcessRunning — the seam over spawning a bundled command-line tool.
//
// This is the ONE abstraction that lets PlayerCore drive yt-dlp/ffmpeg without ever
// touching `Foundation.Process` (which does not exist on iOS, and which the
// downloader boundary gate forbids outside a single sanctioned macOS shell file).
// PlayerCore owns the protocol and the Fake; the macOS shell owns the only production
// conformer.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Why a spawned tool stopped, and with what status.
///
/// Both halves are load-bearing. A tool that exits normally reports its own exit code
/// (yt-dlp's `1` = download error, `2` = invalid arguments, `100` = restart required,
/// `101` = stopped by the engine), which the caller maps onto a ``DownloadError``.
/// A tool killed by a SIGNAL reports the signal number instead — and that is the REAL
/// cancellation path, because cancelling a download sends SIGTERM and escalates to
/// SIGKILL. Collapsing the two into a bare `Int32` would make a cancelled download
/// indistinguishable from a tool that happened to exit 15.
public struct ProcessTermination: Sendable, Equatable, Hashable {
    /// How the process ended.
    public enum Reason: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
        /// The process returned from `main` (or called `exit`); ``status`` is its exit code.
        case normalExit
        /// The process was killed by a signal; ``status`` is the signal number.
        case uncaughtSignal
    }

    /// The exit code for ``Reason/normalExit``, or the signal number for
    /// ``Reason/uncaughtSignal``.
    public let status: Int32
    /// Whether ``status`` is an exit code or a signal number.
    public let reason: Reason

    public init(status: Int32, reason: Reason) {
        self.status = status
        self.reason = reason
    }

    /// A clean exit: status `0` from a normal return.
    public static let success = ProcessTermination(status: 0, reason: .normalExit)

    /// Whether the tool completed its work successfully.
    ///
    /// `false` for every signal termination, including SIGTERM — a killed process did
    /// not finish, whatever its status number happens to be.
    public var isSuccess: Bool {
        reason == .normalExit && status == 0
    }
}

/// One line of output from a spawned tool, or its termination.
///
/// Lines arrive already split — the production conformer buffers partial reads and
/// emits whole lines only, so parsers never see a torn progress record. The stream
/// always ends with exactly one ``terminated(_:)`` event before it finishes.
public enum ToolOutputEvent: Sendable, Equatable, Hashable {
    /// One complete line from standard output, newline stripped.
    case stdout(String)
    /// One complete line from standard error, newline stripped.
    case stderr(String)
    /// The process ended. Always the final event of a stream that ran to completion.
    case terminated(ProcessTermination)
}

/// Spawns a bundled command-line tool and streams its output.
///
/// `Sendable`, not `@MainActor`: conformers are driven from detached tasks.
///
/// # Cancellation
/// Cancellation is TASK cancellation — cancelling the task that consumes the returned
/// stream must terminate the child. The production conformer wires the stream's
/// `onTermination` to SIGTERM, escalating to SIGKILL, and a cancelled stream therefore
/// ends WITHOUT a ``ToolOutputEvent/terminated(_:)`` event. Callers must treat "stream
/// finished without a termination event" as a cancellation, never as success.
public protocol ToolProcessRunning: Sendable {
    /// Launches `tool` with `arguments` and streams its line-oriented output.
    ///
    /// - Parameters:
    ///   - tool: An absolute file URL of the executable. Callers resolve it through
    ///     ``DownloadToolProviding`` — never from inside the signed app bundle at runtime.
    ///   - arguments: The full argument vector, excluding `argv[0]`.
    /// - Returns: A stream of stdout/stderr lines, ending with exactly one
    ///   ``ToolOutputEvent/terminated(_:)`` unless it was cancelled.
    /// - Throws: When the process could not be launched at all (missing/not executable).
    func spawn(tool: URL, arguments: [String]) async throws -> AsyncThrowingStream<ToolOutputEvent, any Error>
}
