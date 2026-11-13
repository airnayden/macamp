// YtDlpProgressParser — the reading half of the engine wire format, and the production
// process-termination map.
//
// # Only the sentinels are parsed
// MacAMP never reads the engine's human-readable output. Lines like
// `[download]  42.0% of 3.51MiB at 1.20MiB/s ETA 00:02` are LOCALIZED, reflowed between
// releases, and carry units that have to be re-parsed to be useful. The
// `--progress-template`/`--print` sentinels this parser matches are the opposite: a
// fixed field count, raw integers, and `NA` for anything unavailable. Every line that
// does not start with a known sentinel is ignored — a malformed or unexpected line
// produces no event and no state change, never a crash.
//
// # Purity
// Nothing here holds state. `cancellationRequested` and the last stderr line are
// PARAMETERS rather than properties precisely so the whole termination contract is
// visible in one signature: the queue service owns "did the person ask to cancel", the
// parser owns "what does this termination mean". The map traps on nothing, including
// the programmer-error row (exit 2) — a `assertionFailure` inside a pure function would
// make its own required test unrunnable in a debug build, and `.invalidArguments`
// already names the fault loudly enough for the caller to assert on if it wants to.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Turns engine output lines into ``DownloadState`` transitions, and a process
/// termination into a ``DownloadOutcome``.
public enum YtDlpProgressParser {
    /// What one recognized output line means.
    ///
    /// The finished path is a separate case rather than a `DownloadState`: seeing it is
    /// necessary but NOT sufficient for success — the termination map still has the
    /// final say, and a file line followed by a non-zero exit is a failure.
    public enum Event: Sendable, Equatable, Hashable {
        /// A lifecycle transition the queue should publish.
        case state(DownloadState)
        /// The finished file's path, exactly as the engine reported it.
        case destination(String)
    }

    /// The engine's documented exit-code ladder.
    ///
    /// ``restartRequired`` and ``stoppedByEngine`` are DEFENSIVE rows: MacAMP passes
    /// neither `-U`/`--update-to` nor any `--max-downloads`/`--break-*` flag, so neither
    /// code should ever be produced. They are mapped anyway so an engine that starts
    /// emitting them lands on a named case instead of ``DownloadError/unknown(code:)``.
    public enum ExitCode {
        /// The engine finished its work.
        public static let success: Int32 = 0
        /// The download itself failed; diagnostics are on stderr.
        public static let downloadError: Int32 = 1
        /// The engine rejected its own arguments — a programming error in the builder.
        public static let invalidArguments: Int32 = 2
        /// The engine updated itself and must be relaunched. Unreachable here.
        public static let restartRequired: Int32 = 100
        /// The engine stopped the download on its own. Unreachable here.
        public static let stoppedByEngine: Int32 = 101
    }

    /// The field count of a well-formed ``YtDlpSentinel/progress`` line's payload:
    /// status, downloaded, total, estimate, eta, speed.
    static let progressFieldCount = 6

    /// The field count of a well-formed ``YtDlpSentinel/postProcess`` payload:
    /// status, postprocessor.
    static let postProcessFieldCount = 2

    /// What `line` means, or `nil` when it is not one of MacAMP's sentinel lines.
    ///
    /// The three prefixes are mutually unambiguous because each ends with the field
    /// separator: `MACAMP-PP|` cannot match `MACAMP-P|`, since the ninth character is
    /// `P` rather than `|`.
    public static func event(from line: String) -> Event? {
        if let fields = payloadFields(of: line, after: YtDlpSentinel.progress) {
            return downloadingEvent(fields: fields)
        }
        if let fields = payloadFields(of: line, after: YtDlpSentinel.postProcess) {
            // Always `fraction: nil`: this sentinel announces the PHASE and carries no
            // conversion progress of its own. A fraction can only come from ffmpeg's own
            // `-progress` file, which `FFProgressFileTailer` reads.
            return fields.count == postProcessFieldCount ? .state(.postProcessing(fraction: nil)) : nil
        }
        if line.hasPrefix(YtDlpSentinel.filePath) {
            return destinationEvent(line: line)
        }
        return nil
    }

    /// Whether `line` is one of MacAMP's own sentinel lines — WELL-FORMED OR NOT.
    ///
    /// The counterpart to ``event(from:)``: that answers "what does this line mean",
    /// this answers "is this line OURS". The caller that needs the second question is
    /// the one deciding whether a stderr line may be kept as a failure diagnostic, and
    /// a sentinel never may — ``YtDlpSentinel/postProcess`` lines are the LAST thing
    /// the engine writes to stderr, so a failed download would otherwise carry
    /// `"MACAMP-PP|finished|MoveFiles"` into ``DownloadError/downloadFailed(detail:)``:
    /// a diagnostic that reads like success and hides the real error.
    ///
    /// Deliberately a PREFIX test rather than `event(from:) != nil`. A sentinel whose
    /// payload is malformed (wrong field count, empty path) still came out of MacAMP's
    /// own `--progress-template`/`--print`, and it is no more a diagnostic than a
    /// well-formed one is.
    public static func isSentinel(_ line: String) -> Bool {
        line.hasPrefix(YtDlpSentinel.progress)
            || line.hasPrefix(YtDlpSentinel.postProcess)
            || line.hasPrefix(YtDlpSentinel.filePath)
    }

    /// What a finished engine process means.
    ///
    /// - Parameters:
    ///   - termination: The exit code or signal number, and which of the two it is.
    ///   - filePath: The path from the ``YtDlpSentinel/filePath`` line, or `nil` when no
    ///     such line was ever seen. Its presence is what separates a real completion
    ///     from a clean exit that produced nothing.
    ///   - lastErrorLine: The last stderr line, carried into
    ///     ``DownloadError/downloadFailed(detail:)`` as a diagnostic. Never presented as
    ///     the primary user-facing message.
    ///   - cancellationRequested: Whether the queue asked for this process to stop. Only
    ///     consulted on the signal path, which is the real cancellation route
    ///     (cancelling sends SIGTERM and escalates to SIGKILL).
    public static func outcome(
        of termination: ProcessTermination,
        filePath: String?,
        lastErrorLine: String?,
        cancellationRequested: Bool
    ) -> DownloadOutcome {
        guard termination.reason == .normalExit else {
            return signalOutcome(signal: termination.status, cancellationRequested: cancellationRequested)
        }
        return exitOutcome(status: termination.status, filePath: filePath, lastErrorLine: lastErrorLine)
    }
}

// MARK: - Termination rows

private extension YtDlpProgressParser {
    /// A signal kill: a cancellation the person asked for, or a fault they did not.
    ///
    /// The unrequested branch's `detail` is a raw diagnostic string, never user-facing
    /// copy — ``DownloadError/message`` supplies the localized text for both branches.
    static func signalOutcome(signal: Int32, cancellationRequested: Bool) -> DownloadOutcome {
        guard cancellationRequested else {
            return .failed(.downloadFailed(detail: "terminated by signal \(signal)"))
        }
        return .failed(.cancelled)
    }

    /// The exit-code ladder.
    ///
    /// A clean exit with NO file line is ``DownloadError/alreadyDownloaded``, not a
    /// generic failure: the realistic way to reach it is re-pasting a video whose file
    /// is already in the destination folder, where the engine skips the work and exits
    /// happily without ever moving a file. The queue turns that into a friendly notice.
    static func exitOutcome(status: Int32, filePath: String?, lastErrorLine: String?) -> DownloadOutcome {
        switch status {
        case ExitCode.success:
            guard let filePath else { return .failed(.alreadyDownloaded) }
            return .completed(filePath: filePath)
        case ExitCode.downloadError:
            return .failed(.downloadFailed(detail: lastErrorLine))
        case ExitCode.invalidArguments:
            return .failed(.invalidArguments)
        case ExitCode.restartRequired:
            return .failed(.engineRestartRequired)
        case ExitCode.stoppedByEngine:
            return .failed(.cancelledByEngine)
        default:
            return .failed(.unknown(code: status))
        }
    }
}

// MARK: - Line parsing

private extension YtDlpProgressParser {
    /// `line`'s payload split on the field separator, or `nil` when it lacks `prefix`.
    ///
    /// Empty subsequences are kept so a missing value shifts nothing — the field count
    /// is what validates the line's shape.
    static func payloadFields(of line: String, after prefix: String) -> [Substring]? {
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false)
    }

    static func downloadingEvent(fields: [Substring]) -> Event? {
        guard fields.count == progressFieldCount else { return nil }
        let downloaded = number(fields[1])
        let speed = number(fields[5]).flatMap { Int64(exactly: $0.rounded()) }
        let eta = number(fields[4]).flatMap { Int(exactly: $0.rounded()) }
        return .state(.downloading(
            fraction: fraction(downloaded: downloaded, total: number(fields[2]), estimate: number(fields[3])),
            speedBytesPerSec: speed,
            etaSeconds: eta
        ))
    }

    /// The path is everything after the sentinel, which ALREADY ends with the separator
    /// — so this splits on the first `|` and no other. A title containing `|` survives
    /// intact, which a naive full split would silently truncate.
    static func destinationEvent(line: String) -> Event? {
        let path = String(line.dropFirst(YtDlpSentinel.filePath.count))
        guard !path.isEmpty else { return nil }
        return .destination(path)
    }

    /// One numeric field, or `nil` for `NA`, an empty field, or anything unusable.
    static func number(_ field: Substring) -> Double? {
        guard let value = Double(field), value.isFinite else { return nil }
        return value
    }

    /// Completion in `0...1`.
    ///
    /// The denominator is the larger of the exact total and the estimate, because the
    /// engine reports only one of them for most of a transfer and reports the exact
    /// total late. An unknown or non-positive denominator yields `0` — an indeterminate
    /// transfer reports no progress rather than a fabricated one.
    static func fraction(downloaded: Double?, total: Double?, estimate: Double?) -> Double {
        guard let downloaded else { return 0 }
        let denominator = max(total ?? 0, estimate ?? 0)
        guard denominator > 0 else { return 0 }
        return min(max(downloaded / denominator, 0), 1)
    }
}
