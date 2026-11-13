// Coverage for `YtDlpProgressParser`: scripted line sequences turn into state
// sequences, malformed and human-readable lines turn into nothing at all, and every
// row of the production termination map is pinned — including BOTH signal branches and
// the clean exit that produced no file.
import Foundation
import Services
import Testing

/// One row of the exit-code ladder, named so a failure reads as the row that broke.
struct TerminationRow: CustomStringConvertible {
    let name: String
    let status: Int32
    let expected: DownloadOutcome

    var description: String {
        name
    }
}

@Suite("yt-dlp progress parser")
struct YtDlpProgressParserTests {
    static let destination = "/Users/test/Music/MacAMP Downloads/Never Gonna Give You Up [dQw4w9WgXcQ].m4a"

    // MARK: - Progress lines

    @Test("a download line becomes a downloading state")
    func downloadLineBecomesDownloading() {
        let event = YtDlpProgressParser.event(from: "MACAMP-P|downloading|512|1024|NA|8|262144")
        #expect(event == .state(.downloading(fraction: 0.5, speedBytesPerSec: 262_144, etaSeconds: 8)))
    }

    /// The engine reports the estimate for most of a transfer and the exact total late,
    /// so the denominator is whichever of the two is larger and usable.
    @Test("the estimate carries the fraction while the exact total is NA")
    func estimateDrivesTheFraction() {
        let event = YtDlpProgressParser.event(from: "MACAMP-P|downloading|500|NA|2000.0|NA|NA")
        #expect(event == .state(.downloading(fraction: 0.25, speedBytesPerSec: nil, etaSeconds: nil)))
    }

    @Test("the larger of total and estimate wins")
    func largerDenominatorWins() {
        let event = YtDlpProgressParser.event(from: "MACAMP-P|downloading|100|1000|500|NA|NA")
        #expect(event == .state(.downloading(fraction: 0.1, speedBytesPerSec: nil, etaSeconds: nil)))
    }

    /// An indeterminate transfer reports no progress rather than a fabricated one.
    @Test(
        "an unusable size reports zero progress",
        arguments: [
            "MACAMP-P|downloading|100|NA|NA|NA|NA",
            "MACAMP-P|downloading|NA|1024|NA|NA|NA",
            "MACAMP-P|downloading|100|0|0|NA|NA",
        ]
    )
    func unusableSizeReportsZero(line: String) {
        #expect(YtDlpProgressParser.event(from: line) == .state(.downloading(
            fraction: 0,
            speedBytesPerSec: nil,
            etaSeconds: nil
        )))
    }

    @Test("a fraction beyond the total is clamped")
    func fractionIsClamped() {
        let event = YtDlpProgressParser.event(from: "MACAMP-P|downloading|2000|1000|NA|NA|NA")
        #expect(event == .state(.downloading(fraction: 1, speedBytesPerSec: nil, etaSeconds: nil)))
    }

    /// The engine writes floats for speed and sometimes for eta; both land as integers.
    @Test("float speed and eta round to integers")
    func floatFieldsRound() {
        let event = YtDlpProgressParser.event(from: "MACAMP-P|downloading|1|2|NA|7.6|1258291.2")
        #expect(event == .state(.downloading(fraction: 0.5, speedBytesPerSec: 1_258_291, etaSeconds: 8)))
    }

    @Test("a post-process line becomes a post-processing state")
    func postProcessLineBecomesPostProcessing() {
        let started = YtDlpProgressParser.event(from: "MACAMP-PP|started|ExtractAudio")
        let finished = YtDlpProgressParser.event(from: "MACAMP-PP|finished|EmbedThumbnail")
        #expect(started == .state(.postProcessing(fraction: nil)))
        #expect(finished == .state(.postProcessing(fraction: nil)))
    }

    // MARK: - The file line

    @Test("a file line becomes a destination")
    func fileLineBecomesDestination() {
        #expect(YtDlpProgressParser.event(from: "MACAMP-FILE|" + Self.destination) == .destination(Self.destination))
    }

    /// A title may legitimately contain the field separator. Splitting on every `|`
    /// would truncate the path at the title; splitting on the first keeps it whole.
    @Test("a pipe inside the title survives the split")
    func pipeInsideTheTitleSurvives() {
        let path = "/Users/test/Music/AC|DC - Thunder | Live [abcdefghijk].m4a"
        #expect(YtDlpProgressParser.event(from: "MACAMP-FILE|" + path) == .destination(path))
    }

    @Test("an empty path is not a destination")
    func emptyPathIsIgnored() {
        #expect(YtDlpProgressParser.event(from: "MACAMP-FILE|") == nil)
    }

    // MARK: - Lines that mean nothing

    /// MacAMP never parses the engine's human-readable output: it is localized,
    /// reflowed between releases, and carries units. Only the sentinels are read.
    @Test(
        "malformed and human-readable lines are ignored",
        arguments: [
            "[download]  42.0% of 3.51MiB at 1.20MiB/s ETA 00:02",
            "[ExtractAudio] Destination: Song.m4a",
            "WARNING: unable to extract thumbnail",
            "MACAMP-P|downloading|512",
            "MACAMP-P|downloading|1|2|3|4|5|6|7",
            "MACAMP-PP|started",
            "MACAMP-PP",
            "MACAMP-FILE",
            "MACAMP-X|whatever",
            "",
        ]
    )
    func unknownLinesAreIgnored(line: String) {
        #expect(YtDlpProgressParser.event(from: line) == nil)
    }

    /// The plan's scripted-sequence scenario: a realistic run maps onto exactly the
    /// state sequence the queue publishes, with the noise dropped in between.
    @Test("a scripted run maps onto its state sequence")
    func scriptedRunMapsOntoStates() {
        let lines = [
            "[youtube] dQw4w9WgXcQ: Downloading webpage",
            "MACAMP-P|downloading|0|1000|NA|NA|NA",
            "MACAMP-P|downloading|250|1000|NA|3|100000",
            "MACAMP-P|downloading|1000|1000|NA|0|100000",
            "MACAMP-PP|started|ExtractAudio",
            "MACAMP-PP|started|EmbedThumbnail",
            "MACAMP-FILE|" + Self.destination,
        ]
        let events = lines.compactMap(YtDlpProgressParser.event(from:))
        #expect(events == [
            .state(.downloading(fraction: 0, speedBytesPerSec: nil, etaSeconds: nil)),
            .state(.downloading(fraction: 0.25, speedBytesPerSec: 100_000, etaSeconds: 3)),
            .state(.downloading(fraction: 1, speedBytesPerSec: 100_000, etaSeconds: 0)),
            .state(.postProcessing(fraction: nil)),
            .state(.postProcessing(fraction: nil)),
            .destination(Self.destination),
        ])
    }

    // MARK: - The termination map

    static let exitLadder: [TerminationRow] = [
        TerminationRow(
            name: "exit 1 → download failed carrying the last stderr line",
            status: 1,
            expected: .failed(.downloadFailed(detail: "ERROR: HTTP Error 403: Forbidden"))
        ),
        TerminationRow(name: "exit 2 → invalid arguments", status: 2, expected: .failed(.invalidArguments)),
        TerminationRow(name: "exit 100 → restart required", status: 100, expected: .failed(.engineRestartRequired)),
        TerminationRow(name: "exit 101 → cancelled by engine", status: 101, expected: .failed(.cancelledByEngine)),
        TerminationRow(name: "exit 3 → unknown", status: 3, expected: .failed(.unknown(code: 3))),
        TerminationRow(name: "exit 137 → unknown", status: 137, expected: .failed(.unknown(code: 137))),
    ]

    @Test("a clean exit that moved a file completes")
    func cleanExitCompletes() {
        let outcome = YtDlpProgressParser.outcome(
            of: .success,
            filePath: Self.destination,
            lastErrorLine: nil,
            cancellationRequested: false
        )
        #expect(outcome == .completed(filePath: Self.destination))
    }

    /// The realistic trigger is re-pasting a video whose file is already in the
    /// destination: the engine skips the work and exits happily without moving a file.
    @Test("a clean exit that moved no file is already-downloaded")
    func cleanExitWithoutFileIsAlreadyDownloaded() {
        let outcome = YtDlpProgressParser.outcome(
            of: .success,
            filePath: nil,
            lastErrorLine: nil,
            cancellationRequested: false
        )
        #expect(outcome == .failed(.alreadyDownloaded))
    }

    @Test("every non-zero exit row maps to its typed error", arguments: exitLadder)
    func exitLadderRows(row: TerminationRow) {
        let outcome = YtDlpProgressParser.outcome(
            of: ProcessTermination(status: row.status, reason: .normalExit),
            filePath: Self.destination,
            lastErrorLine: "ERROR: HTTP Error 403: Forbidden",
            cancellationRequested: false
        )
        #expect(outcome == row.expected)
    }

    @Test("a failure with no diagnostics still carries the typed case")
    func failureWithoutDiagnostics() {
        let outcome = YtDlpProgressParser.outcome(
            of: ProcessTermination(status: 1, reason: .normalExit),
            filePath: nil,
            lastErrorLine: nil,
            cancellationRequested: false
        )
        #expect(outcome == .failed(.downloadFailed(detail: nil)))
    }

    /// SIGTERM→SIGKILL is how the queue really stops a download, so a requested signal
    /// kill must read as a cancellation and never as a fault.
    @Test("a requested signal kill is a cancellation", arguments: [SIGTERM, SIGKILL, SIGINT])
    func requestedSignalIsCancellation(signal: Int32) {
        let outcome = YtDlpProgressParser.outcome(
            of: ProcessTermination(status: signal, reason: .uncaughtSignal),
            filePath: nil,
            lastErrorLine: nil,
            cancellationRequested: true
        )
        #expect(outcome == .failed(.cancelled))
    }

    /// A crash nobody asked for is a FAULT, not a cancellation — reporting it as a
    /// cancellation would make the queue drop the row silently.
    @Test("an unrequested signal kill is a failure", arguments: [SIGTERM, SIGKILL, SIGSEGV])
    func unrequestedSignalIsFailure(signal: Int32) {
        let outcome = YtDlpProgressParser.outcome(
            of: ProcessTermination(status: signal, reason: .uncaughtSignal),
            filePath: nil,
            lastErrorLine: "ignored on this path",
            cancellationRequested: false
        )
        #expect(outcome == .failed(.downloadFailed(detail: "terminated by signal \(signal)")))
    }

    /// `cancellationRequested` is consulted on the signal path only: a process that
    /// finished its work before the signal landed still completed.
    @Test("a cancel request does not rewrite a normal exit")
    func cancelRequestDoesNotRewriteNormalExit() {
        let outcome = YtDlpProgressParser.outcome(
            of: .success,
            filePath: Self.destination,
            lastErrorLine: nil,
            cancellationRequested: true
        )
        #expect(outcome == .completed(filePath: Self.destination))
    }

    /// A file line is necessary but not sufficient — the termination has the final say.
    @Test("a file line does not rescue a non-zero exit")
    func fileLineDoesNotRescueFailure() {
        let outcome = YtDlpProgressParser.outcome(
            of: ProcessTermination(status: 1, reason: .normalExit),
            filePath: Self.destination,
            lastErrorLine: "Postprocessing: Conversion failed!",
            cancellationRequested: false
        )
        #expect(outcome == .failed(.downloadFailed(detail: "Postprocessing: Conversion failed!")))
    }
}
