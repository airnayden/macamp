// CueTrack / CueSheet — the parser's output vocabulary.
//
// This is the contract three later slices consume verbatim: the v20 migration stores
// `startFrame`/`endFrame` as `track.cueStartFrame`/`cueEndFrame`, the scanner upserts one
// `track` row per ``CueTrack`` keyed `(filePath, cueStartFrame)`, and segment playback
// clamps a decoder to `[startFrame, endFrame)`.
//
// Two invariants make that safe:
//   1. ``CueTrack/filePath`` is ALWAYS the AUDIO file, never the `.cue` sidecar. The
//      sheet's own path lives on ``CueSheet/sheetPath``.
//   2. Frames are relative to the track's OWN ``CueTrack/filePath``. In a multi-FILE
//      sheet the offsets restart at each `FILE`, so they are never cumulative.
import Foundation

/// One playable segment named by a CUE sheet.
public struct CueTrack: Equatable, Hashable, Sendable {
    /// The `TRACK nn AUDIO` number, as written (1-based, not an array position).
    public let number: Int

    /// Absolute path of the AUDIO file this segment lives in — never the `.cue` path.
    public let filePath: String

    /// `INDEX 01`, in CD frames relative to ``filePath``. Always present: a track
    /// without one is a ``CueParseError/missingIndexOne(trackNumber:line:)``.
    public let startFrame: Int

    /// Exclusive end, in frames relative to ``filePath``; `nil` means "to end of file".
    ///
    /// Within one `FILE` block a track ends where the NEXT track's `INDEX 01` begins —
    /// the gaps-appended convention (foobar2000's default), which keeps a pre-gap with
    /// the track it was recorded after. ``indexZeroFrame`` is published so a future
    /// consumer can choose the other convention without re-parsing.
    public let endFrame: Int?

    /// `TITLE` inside the `TRACK` block.
    public let title: String?

    /// `PERFORMER` inside the `TRACK` block (the track artist, not the album artist —
    /// that is ``CueSheet/performer``).
    public let performer: String?

    /// `INDEX 00` when the sheet placed the pre-gap INSIDE this track's own file.
    /// Mutually exclusive with ``pregapFrames`` by the CUE spec.
    public let indexZeroFrame: Int?

    /// `PREGAP` — silence a burner GENERATES before the track. It is not present in the
    /// audio file, so it never shifts ``startFrame``.
    public let pregapFrames: Int?

    /// `POSTGAP` — generated silence after the track. Same non-presence rule as
    /// ``pregapFrames``.
    public let postgapFrames: Int?

    /// `true` when this track's pre-gap was declared in the PREVIOUS `FILE` block — the
    /// non-compliant EAC "gaps appended" shape. Provenance only: the segmentation has
    /// already been normalized to match a compliant sheet.
    public let hasAppendedGapInPriorFile: Bool

    public init(
        number: Int,
        filePath: String,
        startFrame: Int,
        endFrame: Int? = nil,
        title: String? = nil,
        performer: String? = nil,
        indexZeroFrame: Int? = nil,
        pregapFrames: Int? = nil,
        postgapFrames: Int? = nil,
        hasAppendedGapInPriorFile: Bool = false
    ) {
        self.number = number
        self.filePath = filePath
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.title = title
        self.performer = performer
        self.indexZeroFrame = indexZeroFrame
        self.pregapFrames = pregapFrames
        self.postgapFrames = postgapFrames
        self.hasAppendedGapInPriorFile = hasAppendedGapInPriorFile
    }

    /// Length in frames, or `nil` when the segment runs to end of file (the length is
    /// then a property of the audio file, which this layer deliberately never opens).
    public var frameCount: Int? {
        endFrame.map { $0 - startFrame }
    }

    /// Length in seconds, or `nil` for an open-ended segment. See ``frameCount``.
    public var durationSeconds: Double? {
        frameCount.map { CueTime.seconds(frames: $0) }
    }
}

/// A `FILE` the sheet named that could not be located on disk.
///
/// Surfaced as data rather than thrown: one dead reference in a multi-FILE sheet must
/// not discard the tracks that DID resolve, and the scanner reports it as a failure
/// count instead of aborting the folder.
public struct CueUnresolvedFileReference: Equatable, Hashable, Sendable {
    /// The operand exactly as written in the sheet (e.g. `"01 - Mojo Pin.wav"`).
    public let fileName: String

    /// 1-based source line of the `FILE` statement.
    public let lineNumber: Int

    /// The `TRACK` numbers lost with it, in sheet order.
    public let trackNumbers: [Int]

    public init(fileName: String, lineNumber: Int, trackNumbers: [Int]) {
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.trackNumbers = trackNumbers
    }
}

/// A parsed CUE sheet: disc-level metadata plus its resolved segments.
public struct CueSheet: Equatable, Sendable {
    /// Absolute path of the `.cue` file itself. Stored by the scanner as
    /// `track.cueSheetPath`; it is also the album-grouping key for a multi-FILE sheet,
    /// where `filePath` differs per track.
    public let sheetPath: String

    /// Disc-level `TITLE` — the album title.
    public let title: String?

    /// Disc-level `PERFORMER` — the album artist.
    public let performer: String?

    /// `REM GENRE`, joined from every operand after the keyword.
    public let genre: String?

    /// `REM DATE`, verbatim. Kept as text because sheets carry both `1997` and
    /// `1997-04-29`, and narrowing that here would lose information the tag layer wants.
    public let date: String?

    /// Every segment whose `FILE` resolved, in sheet order.
    public let tracks: [CueTrack]

    /// Every `FILE` that did not resolve. Empty on a healthy sheet.
    public let unresolvedFiles: [CueUnresolvedFileReference]

    /// `true` when at least one track was folded out of the non-compliant EAC
    /// "gaps appended" shape. Diagnostic only — ``tracks`` is already normalized.
    public let containsEACAppendedGaps: Bool

    public init(
        sheetPath: String,
        title: String? = nil,
        performer: String? = nil,
        genre: String? = nil,
        date: String? = nil,
        tracks: [CueTrack] = [],
        unresolvedFiles: [CueUnresolvedFileReference] = [],
        containsEACAppendedGaps: Bool = false
    ) {
        self.sheetPath = sheetPath
        self.title = title
        self.performer = performer
        self.genre = genre
        self.date = date
        self.tracks = tracks
        self.unresolvedFiles = unresolvedFiles
        self.containsEACAppendedGaps = containsEACAppendedGaps
    }

    /// The distinct audio files the resolved tracks live in, in first-appearance order.
    public var audioFilePaths: [String] {
        var seen: Set<String> = []
        return tracks.compactMap { seen.insert($0.filePath).inserted ? $0.filePath : nil }
    }
}
