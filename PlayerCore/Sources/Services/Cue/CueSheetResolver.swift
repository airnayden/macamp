// CueSheetResolver — the parser's second pass: structure in, playable segments out.
//
// Three steps, in this order, and the order is load-bearing:
//   1. FOLD the non-compliant EAC "gaps appended" shape, because it makes a track number
//      appear twice — which step 2 would otherwise refuse.
//   2. VALIDATE what remains (INDEX 01 mandatory, PREGAP/INDEX 00 exclusivity, unique
//      track numbers, monotonic starts within a file).
//   3. RESOLVE each `FILE` to a path and cut segments, per file block.
//
// # The EAC variant
// Exact Audio Copy, ripping one file per track with "gaps appended to previous track",
// writes the NEXT track's `INDEX 00` inside the CURRENT track's `FILE` block:
//
//     FILE "01 - One.wav" WAVE
//       TRACK 01 AUDIO
//         INDEX 01 00:00:00
//       TRACK 02 AUDIO          <- declared here, INDEX 00 only
//         INDEX 00 05:42:03
//     FILE "02 - Two.wav" WAVE
//       TRACK 02 AUDIO          <- declared AGAIN, with the real INDEX 01
//         INDEX 01 00:00:00
//
// That trailing declaration only records WHERE the appended gap starts inside file 1. It
// names no audio of its own: file 1 already belongs entirely to track 01 (the gap is
// appended to it), and track 02's audio starts at frame 0 of file 2. So the fold drops
// the orphan, keeps its `INDEX 00` as provenance on the real declaration, and leaves
// track 01 running to end of file — which is byte-identically the segmentation a
// COMPLIANT one-file-per-track sheet produces. That equivalence is the acceptance test.
import Foundation

enum CueSheetResolver {
    /// Where a draft lives, so the fold can write through to it.
    private struct DraftLocation {
        let file: Int
        let track: Int
    }

    /// The fold's output: the rewritten blocks plus whether anything was folded.
    private struct FoldResult {
        let files: [CueFileDraft]
        let didFold: Bool
    }

    static func resolve(
        draft: CueSheetDraft,
        sheetURL: URL,
        locator: any CueAudioFileLocating
    ) throws -> CueSheet {
        guard !draft.files.isEmpty else {
            throw CueParseError.emptySheet
        }
        let folded = foldAppendedGaps(draft.files)
        try validate(folded.files)

        let directory = sheetURL.deletingLastPathComponent()
        var tracks: [CueTrack] = []
        var unresolved: [CueUnresolvedFileReference] = []
        for file in folded.files where !file.tracks.isEmpty {
            guard let path = locator.locate(fileName: file.fileName, relativeTo: directory) else {
                unresolved.append(
                    CueUnresolvedFileReference(
                        fileName: file.fileName,
                        lineNumber: file.line,
                        trackNumbers: file.tracks.map(\.number)
                    )
                )
                continue
            }
            tracks.append(contentsOf: segments(in: file, filePath: path))
        }
        return CueSheet(
            sheetPath: sheetURL.path,
            title: draft.title,
            performer: draft.performer,
            genre: draft.genre,
            date: draft.date,
            tracks: tracks,
            unresolvedFiles: unresolved,
            containsEACAppendedGaps: folded.didFold
        )
    }

    // MARK: EAC fold

    /// Removes trailing `INDEX 00`-only track declarations that a LATER `FILE`
    /// re-declares with a real `INDEX 01`.
    ///
    /// The later declaration is required: without it the orphan is simply a track with
    /// no start, and must stay so validation can refuse it as
    /// ``CueParseError/missingIndexOne(trackNumber:line:)``. That single condition is
    /// what separates "non-compliant but recoverable" from "broken".
    private static func foldAppendedGaps(_ input: [CueFileDraft]) -> FoldResult {
        var files = input
        var didFold = false
        // Only tracks are removed, never file blocks, so these indices stay valid.
        for fileIndex in files.indices {
            guard let orphan = files[fileIndex].tracks.last,
                  orphan.indexes[1] == nil,
                  let gapFrames = orphan.indexes[0],
                  let target = laterDeclaration(of: orphan.number, after: fileIndex, in: files)
            else {
                continue
            }
            files[fileIndex].tracks.removeLast()
            files[target.file].tracks[target.track].appendedGapFrames = gapFrames
            mergeMetadata(from: orphan, into: &files[target.file].tracks[target.track])
            didFold = true
        }
        return FoldResult(files: files, didFold: didFold)
    }

    /// The first later block declaring `number` with an `INDEX 01`.
    private static func laterDeclaration(
        of number: Int,
        after fileIndex: Int,
        in files: [CueFileDraft]
    ) -> DraftLocation? {
        for candidateFile in files.indices where candidateFile > fileIndex {
            for candidateTrack in files[candidateFile].tracks.indices {
                let draft = files[candidateFile].tracks[candidateTrack]
                if draft.number == number, draft.indexes[1] != nil {
                    return DraftLocation(file: candidateFile, track: candidateTrack)
                }
            }
        }
        return nil
    }

    /// EAC repeats `TITLE`/`PERFORMER` in both declarations, but a hand-edited sheet may
    /// only fill the orphan. The real declaration wins; the orphan is a fallback.
    private static func mergeMetadata(from orphan: CueTrackDraft, into target: inout CueTrackDraft) {
        target.title = target.title ?? orphan.title
        target.performer = target.performer ?? orphan.performer
    }

    // MARK: Validation

    private static func validate(_ files: [CueFileDraft]) throws {
        var declared: Set<Int> = []
        for file in files {
            try validateBlock(file)
            for track in file.tracks where !declared.insert(track.number).inserted {
                throw CueParseError.duplicateTrackNumber(track.number, line: track.line)
            }
        }
    }

    private static func validateBlock(_ file: CueFileDraft) throws {
        var previousStart: Int?
        for track in file.tracks {
            guard let start = track.indexes[1] else {
                throw CueParseError.missingIndexOne(trackNumber: track.number, line: track.line)
            }
            if track.pregapFrames != nil, track.indexes[0] != nil {
                throw CueParseError.conflictingPregap(trackNumber: track.number, line: track.line)
            }
            if let previousStart, start <= previousStart {
                throw CueParseError.nonMonotonicIndexOne(trackNumber: track.number, line: track.line)
            }
            previousStart = start
        }
    }

    // MARK: Segmentation

    /// Cuts one `FILE` block into segments.
    ///
    /// A track ends where the NEXT track in the SAME file starts (`INDEX 01`), and the
    /// last track of a block ends at end of file (`nil`). Using the successor's
    /// `INDEX 01` rather than its `INDEX 00` keeps a pre-gap with the track it was
    /// recorded after — the gaps-appended convention. ``CueTrack/indexZeroFrame``
    /// preserves the other boundary for any consumer that wants it.
    private static func segments(in file: CueFileDraft, filePath: String) -> [CueTrack] {
        let drafts = file.tracks
        return drafts.enumerated().compactMap { offset, draft in
            // `validate` already proved INDEX 01 exists on every surviving draft.
            guard let start = draft.indexes[1] else {
                return nil
            }
            let successor = drafts.indices.contains(offset + 1) ? drafts[offset + 1] : nil
            return CueTrack(
                number: draft.number,
                filePath: filePath,
                startFrame: start,
                endFrame: successor?.indexes[1],
                title: draft.title,
                performer: draft.performer,
                indexZeroFrame: draft.indexes[0],
                pregapFrames: draft.pregapFrames,
                postgapFrames: draft.postgapFrames,
                hasAppendedGapInPriorFile: draft.appendedGapFrames != nil
            )
        }
    }
}
