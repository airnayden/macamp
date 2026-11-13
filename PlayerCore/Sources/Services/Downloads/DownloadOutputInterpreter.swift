// DownloadOutputInterpreter — turns one download run's raw output lines into the states
// the queue publishes, the finished file's path, and the diagnostic a failure carries.
//
// ── WHICH STREAM CARRIES WHICH SENTINEL (measured 2026-09-10) ────────────────
//
// A real `yt-dlp_macos` run of MacAMP's own argument vector, with the two streams
// captured separately, produced:
//
//     STDOUT:  MACAMP-P| ×9    MACAMP-FILE| ×1    MACAMP-PP| ×0
//     STDERR:  MACAMP-P| ×0                       MACAMP-PP| ×8
//
// The engine writes the `postprocess:` progress template to STDERR, while download
// progress and `--print` go to STDOUT. That assignment is yt-dlp's own — nothing in
// MacAMP's argument vector chooses it — so this type reads sentinels from BOTH streams
// and never consults which stream a line arrived on to decide what it MEANS.
//
// A driver that parsed stdout alone made ``DownloadState/postProcessing`` UNREACHABLE
// in production: `YtDlpProgressParser` never received a `MACAMP-PP|` line, so the row
// kept its last stdout state — `MACAMP-P|finished`, drawn as a full progress bar — for
// the whole extract/tag phase. On a 19-second clip that is a second nobody sees; on a
// large file ExtractAudio plus EmbedThumbnail take minutes and the app looks frozen.
// The state, its copy and its unit tests were all correct and green; only the wiring
// never delivered the line. Parse both streams, and it cannot happen again if yt-dlp
// moves a template to the other stream.
//
// The stream DOES decide exactly one thing: whether a line may become the failure
// diagnostic. See ``DownloadOutputInterpreter/lastErrorLine``.
//
// ── ORDERING (why the post-processing latch exists) ──────────────────────────
//
// The same capture's true line order was:
//
//     1–8   MACAMP-P|downloading|…                                  (stdout)
//     9     MACAMP-P|finished|252182|252182|NA|NA|…                 (stdout)
//     10–17 MACAMP-PP|started|ExtractAudio … MACAMP-PP|finished|MoveFiles   (stderr)
//     18    MACAMP-FILE|/…/Me at the zoo [jNQXAC9IVRw].m4a          (stdout)
//
// Two streams are drained independently, so their interleaving is NOT guaranteed: the
// `finished` sample on line 9 — or a later stalled-transfer sample — can legitimately
// be delivered after the stderr post-process lines. Once post-processing is announced
// the interpreter therefore REFUSES every later `.downloading` sample, so the pane
// cannot snap back from "Converting audio…" to a full download bar and flicker.
//
// The other orderings need no defence, and this records why rather than leaving the
// absence to look like an oversight:
//
// - `.postProcessing` can never overwrite a TERMINAL state. The parser emits only
//   `.downloading` and `.postProcessing`; every terminal state is published by the
//   driver's `applyOutcome`, strictly after this loop has finished draining, and
//   `publishProgress` drops any sample for a row that has already left the queue.
// - Repeated `.postProcessing` (the capture had eight) costs nothing: `emitItemState`
//   skips a sample identical to the previous one.
// - `MACAMP-FILE|` stays the SOLE authority for the finished path, is accepted from
//   either stream in any position, and the latch never touches it.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Which of a spawned tool's two output streams a line arrived on.
///
/// Named rather than a `Bool` because the distinction is load-bearing in exactly one
/// direction: it never decides what a line MEANS, only whether it may be kept as the
/// failure diagnostic.
enum DownloadOutputStream {
    case standardOutput
    case standardError
}

/// Accumulates one download run's output: the finished path, the failure diagnostic,
/// and the phase latch that keeps a late transfer sample from rewinding the row.
struct DownloadOutputInterpreter {
    /// The finished file's path from the ``YtDlpSentinel/filePath`` line, or `nil` when
    /// no such line ever arrived — which is what separates a real completion from a
    /// clean exit that produced nothing.
    private(set) var filePath: String?

    /// The last stderr line that was NOT one of MacAMP's own sentinels, carried into
    /// ``DownloadError/downloadFailed(detail:)``.
    ///
    /// Sentinels are excluded because they are the LAST thing the engine writes to
    /// stderr: recording them unconditionally made a failed download report
    /// `"MACAMP-PP|finished|MoveFiles"` as its diagnostic — engine wire format that
    /// reads like success, in place of the `ERROR:` line that explained the failure.
    private(set) var lastErrorLine: String?

    /// Whether post-processing has been announced. Once set, a `.downloading` sample is
    /// a straggler from the other stream and is refused — see ORDERING in the header.
    private var sawPostProcessing = false

    /// Interprets one output line, returning the state the queue should publish.
    ///
    /// Sentinels are recognized on EITHER stream; `stream` only gates the diagnostic.
    mutating func interpret(_ line: String, from stream: DownloadOutputStream) -> DownloadState? {
        switch YtDlpProgressParser.event(from: line) {
        case let .state(state):
            return admissible(state)
        case let .destination(path):
            filePath = path
            return nil
        case nil:
            recordDiagnostic(line, from: stream)
            return nil
        }
    }

    /// `state`, unless publishing it would move the row BACKWARDS out of post-processing.
    private mutating func admissible(_ state: DownloadState) -> DownloadState? {
        switch state {
        case .postProcessing:
            sawPostProcessing = true
            return state
        case .downloading:
            return sawPostProcessing ? nil : state
        case .queued, .fetchingMetadata, .finished, .failed, .cancelled:
            // Unreachable from the parser, which emits only the two phases above. Listed
            // exhaustively so a future parser event has to be considered here.
            return state
        }
    }

    /// Keeps `line` as the failure diagnostic when it is a real message from the engine.
    private mutating func recordDiagnostic(_ line: String, from stream: DownloadOutputStream) {
        guard case .standardError = stream, !YtDlpProgressParser.isSentinel(line) else { return }
        lastErrorLine = line
    }
}
