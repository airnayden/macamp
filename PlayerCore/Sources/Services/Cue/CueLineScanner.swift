// CueLineScanner — the CUE grammar's lexical layer.
//
// A cue sheet is line-oriented: `COMMAND operand operand …`, where an operand may be a
// double-quoted string containing spaces. Indentation is purely cosmetic and carries no
// meaning (the nesting a reader perceives comes from the command sequence, not the
// leading whitespace), so it is discarded here.
//
// Everything in this file is pure: no filesystem, no semantics, no validation beyond
// "what are the tokens on this line". Semantic refusals live in `CueSheetParser`.
import Foundation

/// One tokenized, non-blank line of a CUE sheet.
struct CueStatement: Equatable {
    /// The command, upper-cased. Sheets in the wild are inconsistent about case even
    /// though the format specifies uppercase, so dispatch is case-insensitive.
    let command: String

    /// Everything after the command, with quotes stripped.
    let operands: [String]

    /// 1-based source line, so a diagnostic can point at the text the user edited.
    let lineNumber: Int

    /// The operand at `index`, or `nil` when the line was short.
    func operand(_ index: Int) -> String? {
        operands.indices.contains(index) ? operands[index] : nil
    }

    /// Operands from `index` onward joined with single spaces.
    ///
    /// This is how unquoted free text survives: `REM GENRE Alternative Rock` tokenizes
    /// to three operands after the keyword, and a quoted `TITLE "Cowboys"` collapses to
    /// exactly itself because it is already one token.
    func joinedOperands(from index: Int) -> String? {
        guard operands.indices.contains(index) else {
            return nil
        }
        let text = operands[index...].joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}

enum CueLineScanner {
    /// Format keywords a `FILE` statement may end with. Stripped so an UNQUOTED file
    /// name containing spaces still rejoins correctly.
    static let fileFormatKeywords: Set<String> = [
        "WAVE", "MP3", "AIFF", "FLAC", "BINARY", "MOTOROLA",
    ]

    /// Tokenizes every non-blank line, preserving 1-based source line numbers.
    ///
    /// CRLF is normalized first so a Windows-authored sheet (which is most of them)
    /// numbers identically to a Unix one, matching `PlaylistParser`'s precedent.
    static func statements(in contents: String) -> [CueStatement] {
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var statements: [CueStatement] = []
        for (index, line) in normalized.components(separatedBy: "\n").enumerated() {
            let tokens = tokens(in: stripBOM(line))
            guard let command = tokens.first else {
                continue
            }
            statements.append(
                CueStatement(
                    command: command.uppercased(),
                    operands: Array(tokens.dropFirst()),
                    lineNumber: index + 1
                )
            )
        }
        return statements
    }

    /// Splits a line into whitespace-separated tokens, honouring double quotes.
    ///
    /// An UNTERMINATED quote consumes to end of line rather than failing. Being strict
    /// there would reject otherwise-usable real-world sheets over a cosmetic typo in a
    /// title, and the quote is not load-bearing for any value the parser acts on.
    static func tokens(in line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        for character in line {
            if character == "\"" {
                if isQuoted {
                    tokens.append(current)
                    current = ""
                }
                isQuoted.toggle()
            } else if !isQuoted, character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    /// The file name a `FILE` statement's operands name.
    ///
    /// Drops a trailing format keyword, then rejoins — so both
    /// `FILE "01 - Track.wav" WAVE` and the unquoted `FILE 01 - Track.wav WAVE` yield
    /// the same name.
    static func fileName(from operands: [String]) -> String? {
        var parts = operands
        if let last = parts.last, fileFormatKeywords.contains(last.uppercased()) {
            parts.removeLast()
        }
        let name = parts.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// Removes a UTF-8 byte-order mark, which lands on the FIRST line only and would
    /// otherwise make its command token unrecognisable.
    private static func stripBOM(_ line: String) -> String {
        line.hasPrefix("\u{FEFF}") ? String(line.dropFirst()) : line
    }
}
