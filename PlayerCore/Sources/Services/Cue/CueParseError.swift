// CueParseError — every way a CUE sheet can be refused.
//
// One typed surface so a caller writes a single `catch`. Every case that can name a
// source location does, because a cue sheet is hand-edited text and "line 34" is the
// only actionable part of the diagnostic.
//
// A DEAD FILE REFERENCE IS NOT AN ERROR. A `FILE` that does not exist on disk is
// reported as data (``CueSheet/unresolvedFiles``) rather than thrown, so one bad
// reference in a multi-FILE sheet cannot discard the tracks that did resolve.
import Foundation

/// Every way ``CueSheetParser`` can refuse a sheet.
public enum CueParseError: Error, Sendable, Equatable {
    /// The text contained no `FILE` statement at all — not a cue sheet.
    case emptySheet

    /// A `TRACK` appeared before any `FILE`. There is nothing for its indexes to be
    /// relative to.
    case trackOutsideFile(trackNumber: Int, line: Int)

    /// An `INDEX`, `PREGAP`, or `POSTGAP` appeared before any `TRACK`.
    case indexOutsideTrack(line: Int)

    /// A `TRACK` never received an `INDEX 01`.
    ///
    /// `INDEX 01` is the only mandatory index — it IS the track's start. Note that a
    /// trailing `INDEX 00`-only `TRACK` is not automatically this error: when a LATER
    /// `FILE` re-declares the same number with an `INDEX 01`, it is the EAC
    /// gaps-appended shape and gets folded instead.
    case missingIndexOne(trackNumber: Int, line: Int)

    /// A timecode was not `MM:SS:FF` with `SS < 60` and `FF < 75`.
    case malformedTimecode(String, line: Int)

    /// `TRACK <n>` where `<n>` was not a number.
    case malformedTrackNumber(String, line: Int)

    /// `INDEX <n>` where `<n>` was not a number.
    case malformedIndexNumber(String, line: Int)

    /// The same `INDEX` number was given twice inside one `TRACK`.
    case duplicateIndex(number: Int, trackNumber: Int, line: Int)

    /// A track declared BOTH `PREGAP` and `INDEX 00`.
    ///
    /// They are mutually exclusive by the format: `PREGAP` is silence the burner
    /// generates (absent from the audio file) while `INDEX 00` is silence that is
    /// physically present. Honouring both would double-count the gap.
    case conflictingPregap(trackNumber: Int, line: Int)

    /// The same `TRACK` number was declared twice outside the EAC fold.
    case duplicateTrackNumber(Int, line: Int)

    /// Within one `FILE`, a track's `INDEX 01` did not advance past its predecessor's.
    ///
    /// Refused rather than tolerated: a track's end is its successor's start, so a
    /// non-advancing pair produces a zero- or negative-length segment — which would
    /// reach the database as a nonsense frame range and the decoder as an impossible
    /// clamp.
    case nonMonotonicIndexOne(trackNumber: Int, line: Int)

    /// A statement was missing an operand it cannot work without.
    case missingOperand(command: String, line: Int)

    /// The `.cue` file itself could not be read or decoded as text.
    case unreadableSheet(path: String)
}
