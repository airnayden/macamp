// FFProgressFileTailer — reads ffmpeg's `-progress` blocks into one honest fraction.
//
// ── WHAT ffmpeg WRITES ───────────────────────────────────────────────────────
//
// `-progress <file>` makes ffmpeg append a block of `key=value` lines every second or
// so, each block terminated by its own `progress=continue` line, and the run terminated
// by a single `progress=end` block:
//
//     bitrate=N/A
//     out_time_us=60093792
//     out_time_ms=60093792
//     out_time=00:01:00.093792
//     progress=continue
//     …
//     out_time_us=150093792
//     progress=end
//
// `out_time_us` is the key this reads. `out_time_ms` is present too and carries the SAME
// MICROSECOND value — ffmpeg's `_ms` suffix is a long-standing misnomer — so reading it
// would be right by accident and wrong the day it is fixed (measured, todo 8).
//
// ── WHY `progress=end` REPORTS nil RATHER THAN 1.0 ───────────────────────────
//
// The terminal block carries the FULL duration (`out_time_us=150093792` for a 150.09 s
// stream), so it is the one sample that would legitimately compute to 1.0. It must not:
// yt-dlp runs `EmbedThumbnail`, `Metadata` and `MoveFiles` AFTER the extraction ffmpeg
// exits, and a bar frozen at 100% through those passes is exactly the dishonesty this
// whole path removes. `nil` puts the row back on the indeterminate indicator under an
// unchanged caption, which is the truth: still working, no longer measurable.
//
// ── WHY A PARTIAL TRAILING BLOCK IS DISCARDED ────────────────────────────────
//
// The file is polled while ffmpeg is writing it, so the last block can be half-present.
// A sample is therefore committed only when its own `progress=` line has been seen; an
// unterminated trailing block is dropped whole. Without that, a torn `out_time_us=15`
// read out of `out_time_us=150093792` would snap the bar to ~0 for a frame.
//
// Nothing here touches the filesystem — the caller reads the file and hands the bytes
// in, which is what makes every case above assertable from a string literal.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Turns the contents of an ffmpeg `-progress` file into a conversion fraction.
public enum FFProgressFileTailer {
    /// The elapsed-output-time key, in MICROSECONDS despite what its sibling is named.
    static let outTimeKey = "out_time_us"

    /// The per-block terminator key: `continue` for every block but the last, `end` once.
    static let progressKey = "progress"

    /// The terminator value that means ffmpeg has finished this pass.
    static let endValue = "end"

    static let microsecondsPerSecond: Double = 1_000_000

    /// How far through the conversion `contents` reports, in `0...1`, or `nil` when there
    /// is nothing honest to draw.
    ///
    /// `nil` is returned — never a guess — when the duration is unknown (the `-J`
    /// prefetch failed, so there is no denominator), when no complete sample has arrived
    /// yet, and from the terminal `progress=end` block onwards.
    ///
    /// Unparseable lines are ignored individually rather than failing the read: the file
    /// is sampled mid-write, and one malformed line must not discard the block around it.
    public static func fraction(inContents contents: String, durationSeconds: Double?) -> Double? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        var pendingMicroseconds: Double?
        var committedMicroseconds: Double?
        var reachedEnd = false
        // `\.isNewline`, not `$0 == "\n" || $0 == "\r"`: Swift groups CR-LF into ONE
        // grapheme cluster, so comparing against either character alone silently fails to
        // split a CR-LF file and the whole thing is read as a single unparseable line.
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator]
            let value = line[line.index(after: separator)...]
            if key == outTimeKey {
                pendingMicroseconds = microseconds(value)
            } else if key == progressKey {
                committedMicroseconds = pendingMicroseconds ?? committedMicroseconds
                pendingMicroseconds = nil
                reachedEnd = value == endValue
            }
        }
        guard !reachedEnd, let committedMicroseconds else { return nil }
        return min(max(committedMicroseconds / (durationSeconds * microsecondsPerSecond), 0), 1)
    }

    /// One `out_time_us` value, or `nil` for `N/A`, a torn field, or the sentinel
    /// negative ffmpeg emits before the first frame is muxed.
    private static func microseconds(_ field: Substring) -> Double? {
        guard let value = Double(field), value.isFinite, value >= 0 else { return nil }
        return value
    }
}
