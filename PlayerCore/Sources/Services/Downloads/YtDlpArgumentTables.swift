// YtDlpArgumentTables — the pinned engine literals, expressed as DATA rather than code.
//
// Two kinds of literal live here, and both are a CONTRACT with the download engine:
// the per-format `--audio-quality` values, and the `MACAMP-*` sentinel prefixes that
// the argument builder writes into `--progress-template`/`--print` and the progress
// parser reads back out. Keeping the prefixes in ONE place is what makes the writing
// side and the reading side provably the same wire format — a rename that touched only
// the builder would otherwise leave the parser silently matching nothing.
//
// The quality map is a dictionary, not a `switch` ladder, for two reasons. The obvious
// one is the cyclomatic-complexity budget: a nested format × quality `switch` is twelve
// arms in a single function. The load-bearing one is readability — the values differ in
// KIND between rows (see ``YtDlpArgumentTables/audioQuality``), and a table shows the
// whole contract at a glance and lets a test walk it exhaustively.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// The machine-readable line prefixes MacAMP asks the engine to print.
///
/// These are a WIRE FORMAT shared by ``YtDlpCommandBuilder`` (which composes them into
/// `--progress-template` / `--print` templates) and ``YtDlpProgressParser`` (which
/// matches them on the way back). They are deliberately unlikely to collide with the
/// engine's own human-readable output, which MacAMP never parses.
public enum YtDlpSentinel {
    /// Transfer progress: `MACAMP-P|status|downloaded|total|estimate|eta|speed`.
    public static let progress = "MACAMP-P|"
    /// Post-processing progress: `MACAMP-PP|status|postprocessor`.
    public static let postProcess = "MACAMP-PP|"
    /// The finished file's path: `MACAMP-FILE|<path>`.
    ///
    /// Split on the FIRST separator only — a video title may legitimately contain `|`.
    public static let filePath = "MACAMP-FILE|"
}

/// The pinned per-format `--audio-quality` values.
public enum YtDlpArgumentTables {
    /// The `--audio-quality` value for every format × quality pair the app can ask for.
    ///
    /// # Why the values differ in KIND between rows
    /// - **mp3** — `"0"` / `"5"` / `"7"` are libmp3lame's `-q:a` VBR scale (0 best,
    ///   9 worst). A bitrate string here would silently switch the encoder to CBR.
    /// - **m4a / aac** — bitrate strings, deliberately NOT the numeric scale: a numeric
    ///   quality routes ffmpeg's native AAC encoder onto its EXPERIMENTAL VBR path.
    /// - **opus** — bitrate strings because libopus has no 0–10 VBR scale at all.
    /// - **flac** — the row is EMPTY: the format is lossless, so no quality argument is
    ///   emitted at all. Not an empty string — the flag AND its value are both absent.
    ///
    /// An empty row and an absent row both mean "emit nothing", so ``DownloadAudioFormat/flac``
    /// is written out explicitly and a test asserts every case has a row. Without that,
    /// a format added later would inherit flac's silence by accident rather than by
    /// decision.
    ///
    /// These literals are DECIDED here, not measured: a probe against a real binary is
    /// confirmation evidence, never a decision input. A discrepancy is a finding to
    /// surface, not a reason to edit this table in place.
    public static let audioQuality: [DownloadAudioFormat: [DownloadAudioQuality: String]] = [
        .mp3: [.best: "0", .high: "5", .medium: "7"],
        .m4a: [.best: "256K", .high: "192K", .medium: "128K"],
        .opus: [.best: "192K", .high: "128K", .medium: "96K"],
        .flac: [:],
    ]

    /// The `--audio-quality` value for `format` at `quality`, or `nil` when the format
    /// takes no quality argument at all (``DownloadAudioFormat/flac``).
    ///
    /// A `nil` result means the caller emits NEITHER `--audio-quality` nor a value.
    public static func audioQualityArgument(
        format: DownloadAudioFormat,
        quality: DownloadAudioQuality
    ) -> String? {
        audioQuality[format]?[quality]
    }
}
