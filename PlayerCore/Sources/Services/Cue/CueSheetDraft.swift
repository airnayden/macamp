// CueSheetDraft — the parser's first pass: statements in, structure out.
//
// This layer accumulates exactly what the sheet SAYS, per `FILE` block, with no
// interpretation: no end frames, no EAC folding, no filesystem. Refusals raised here are
// purely syntactic (a `TRACK` before any `FILE`, a timecode that is not `MM:SS:FF`).
// Everything semantic belongs to `CueSheetResolver`.
//
// Keeping the two passes apart is what makes the EAC fold possible at all: a sheet's
// non-compliance is only visible once the whole file list exists, so the first pass must
// not have already rejected the shape.
import Foundation

/// One `TRACK` block exactly as written.
struct CueTrackDraft {
    let number: Int
    let line: Int
    var title: String?
    var performer: String?
    /// INDEX number → frame offset, relative to the enclosing `FILE`.
    var indexes: [Int: Int] = [:]
    var pregapFrames: Int?
    var postgapFrames: Int?
    /// Set by the EAC fold: the `INDEX 00` this track carried in the PREVIOUS file.
    var appendedGapFrames: Int?
}

/// One `FILE` block and the tracks declared under it, in sheet order.
struct CueFileDraft {
    let fileName: String
    let line: Int
    var tracks: [CueTrackDraft] = []
}

/// Accumulator for the first pass.
struct CueSheetDraft {
    var title: String?
    var performer: String?
    var genre: String?
    var date: String?
    var files: [CueFileDraft] = []

    /// Folds one tokenized statement into the draft.
    ///
    /// Unhandled commands (`FLAGS`, `ISRC`, `CATALOG`, `SONGWRITER`, `CDTEXTFILE`, …)
    /// are ignored rather than refused: they carry no information this parser acts on,
    /// and rejecting an unknown command would break on every sheet a future ripper
    /// decides to annotate.
    mutating func apply(_ statement: CueStatement) throws {
        switch statement.command {
        case "FILE":
            try applyFile(statement)
        case "TRACK":
            try applyTrack(statement)
        case "INDEX":
            try applyIndex(statement)
        case "PREGAP", "POSTGAP":
            try applyGap(statement)
        case "TITLE", "PERFORMER":
            applyText(statement)
        case "REM":
            applyRemark(statement)
        default:
            break
        }
    }

    // MARK: Commands

    private mutating func applyFile(_ statement: CueStatement) throws {
        guard let name = CueLineScanner.fileName(from: statement.operands) else {
            throw CueParseError.missingOperand(command: statement.command, line: statement.lineNumber)
        }
        files.append(CueFileDraft(fileName: name, line: statement.lineNumber))
    }

    private mutating func applyTrack(_ statement: CueStatement) throws {
        guard let raw = statement.operand(0) else {
            throw CueParseError.missingOperand(command: statement.command, line: statement.lineNumber)
        }
        guard let number = Int(raw), number > 0 else {
            throw CueParseError.malformedTrackNumber(raw, line: statement.lineNumber)
        }
        guard !files.isEmpty else {
            throw CueParseError.trackOutsideFile(trackNumber: number, line: statement.lineNumber)
        }
        files[files.count - 1].tracks.append(
            CueTrackDraft(number: number, line: statement.lineNumber)
        )
    }

    private mutating func applyIndex(_ statement: CueStatement) throws {
        guard let rawNumber = statement.operand(0), let rawTime = statement.operand(1) else {
            throw CueParseError.missingOperand(command: statement.command, line: statement.lineNumber)
        }
        guard let number = Int(rawNumber), number >= 0 else {
            throw CueParseError.malformedIndexNumber(rawNumber, line: statement.lineNumber)
        }
        guard let time = CueTime(timecode: rawTime) else {
            throw CueParseError.malformedTimecode(rawTime, line: statement.lineNumber)
        }
        try mutateCurrentTrack(line: statement.lineNumber) { draft in
            guard draft.indexes[number] == nil else {
                throw CueParseError.duplicateIndex(
                    number: number,
                    trackNumber: draft.number,
                    line: statement.lineNumber
                )
            }
            draft.indexes[number] = time.totalFrames
        }
    }

    private mutating func applyGap(_ statement: CueStatement) throws {
        guard let rawTime = statement.operand(0) else {
            throw CueParseError.missingOperand(command: statement.command, line: statement.lineNumber)
        }
        guard let time = CueTime(timecode: rawTime) else {
            throw CueParseError.malformedTimecode(rawTime, line: statement.lineNumber)
        }
        let isPregap = statement.command == "PREGAP"
        try mutateCurrentTrack(line: statement.lineNumber) { draft in
            if isPregap {
                draft.pregapFrames = time.totalFrames
            } else {
                draft.postgapFrames = time.totalFrames
            }
        }
    }

    /// `TITLE` / `PERFORMER` bind to the current `TRACK` when there is one, and to the
    /// disc otherwise — which is exactly how the format scopes them.
    private mutating func applyText(_ statement: CueStatement) {
        guard let value = statement.joinedOperands(from: 0) else {
            return
        }
        let isTitle = statement.command == "TITLE"
        guard hasCurrentTrack else {
            if isTitle {
                title = value
            } else {
                performer = value
            }
            return
        }
        try? mutateCurrentTrack(line: statement.lineNumber) { draft in
            if isTitle {
                draft.title = value
            } else {
                draft.performer = value
            }
        }
    }

    /// Only `REM GENRE` and `REM DATE` carry meaning here; every other remark
    /// (`REM COMMENT`, `REM DISCID`, ripper banners) is discarded.
    private mutating func applyRemark(_ statement: CueStatement) {
        guard let keyword = statement.operand(0)?.uppercased(),
              let value = statement.joinedOperands(from: 1)
        else {
            return
        }
        switch keyword {
        case "GENRE":
            genre = value
        case "DATE":
            date = value
        default:
            break
        }
    }

    // MARK: Current-track access

    private var hasCurrentTrack: Bool {
        files.last?.tracks.isEmpty == false
    }

    /// Applies `body` to the most recently declared `TRACK`, refusing when there is
    /// none — an `INDEX`/`PREGAP`/`POSTGAP` with nothing to attach to is malformed.
    private mutating func mutateCurrentTrack(
        line: Int,
        _ body: (inout CueTrackDraft) throws -> Void
    ) throws {
        guard let fileIndex = files.indices.last, !files[fileIndex].tracks.isEmpty else {
            throw CueParseError.indexOutsideTrack(line: line)
        }
        let trackIndex = files[fileIndex].tracks.count - 1
        try body(&files[fileIndex].tracks[trackIndex])
    }
}
