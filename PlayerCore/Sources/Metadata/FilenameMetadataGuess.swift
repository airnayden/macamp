// FilenameMetadataGuess — derives a best-effort (artist, title) pair from a file
// name, for tracks that carry no usable tags.
//
// Pure Foundation, zero I/O: the path is treated as TEXT only — nothing is read
// from disk, nothing is written — so the guess is deterministic and testable
// without fixtures.
//
// The algorithm is deliberately conservative. It strips only what is
// unambiguously bookkeeping (a leading track number that is FOLLOWED by
// separator punctuation) and never touches parenthesised or bracketed content:
// "(Live)" and "[Remaster]" are meaningful search terms, not noise.
import Foundation

/// Derives a best-effort artist/title pair from a file path.
public enum FilenameMetadataGuess {
    /// Guesses `(artist, title)` from the file name of `filePath`.
    ///
    /// The steps, in order: take the last path component minus ONE extension,
    /// NFC-normalise it, turn underscores into spaces, collapse whitespace runs,
    /// drop a leading track-number prefix (only when separator punctuation
    /// follows it), then split on the FIRST ` - ` / ` – ` / ` — ` delimiter.
    ///
    /// Returns `(nil, nil)` for an empty path, a directory path (one ending in
    /// `/`), or a name that collapses to nothing. `artist` is `nil` whenever the
    /// name carries no delimiter — the whole remaining stem becomes the title.
    public static func guess(fromFilePath filePath: String) -> (artist: String?, title: String?) {
        guard let stem = normalizedStem(of: filePath) else { return (nil, nil) }
        let body = strippingTrackNumberPrefix(stem)
        guard let (lead, rest) = splitOnFirstDelimiter(body) else {
            return (nil, blankToNil(body))
        }
        return (blankToNil(lead), blankToNil(rest))
    }
}

// MARK: - Steps

private extension FilenameMetadataGuess {
    /// Steps 1–4: last path component minus ONE extension, NFC-normalised, with
    /// underscores as spaces and whitespace runs collapsed. Returns `nil` when
    /// the path names no file — empty, or a trailing-`/` directory path (which
    /// includes the root `"/"`).
    static func normalizedStem(of filePath: String) -> String? {
        guard !filePath.isEmpty, !filePath.hasSuffix("/") else { return nil }
        let name = (filePath as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let normalized = stem.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "_", with: " ")
        let collapsed = collapsingWhitespace(normalized)
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Collapses every whitespace run to a single space and trims both ends.
    static func collapsingWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Step 5: drops a leading track-number prefix. Only a number FOLLOWED by
    /// separator punctuation is bookkeeping — a bare number plus space is kept
    /// because it may be the title itself ("99 Luftballons").
    static func strippingTrackNumberPrefix(_ text: String) -> String {
        guard let range = text.range(of: trackNumberPrefixPattern, options: .regularExpression),
              range.lowerBound == text.startIndex
        else { return text }
        return String(text[range.upperBound...])
    }

    /// Step 6: splits on the EARLIEST delimiter occurrence, whichever dash it
    /// uses. Returns `nil` when the name carries no delimiter at all.
    static func splitOnFirstDelimiter(_ text: String) -> (String, String)? {
        let matches = artistTitleDelimiters.compactMap { text.range(of: $0) }
        guard let split = matches.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        return (String(text[..<split.lowerBound]), String(text[split.upperBound...]))
    }

    /// Step 7: trims, then maps a blank result to `nil`.
    static func blankToNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Patterns

/// Matches a leading track number ONLY when separator punctuation follows it:
/// `"01 - X"`, `"07. X"`, `"3) X"`. A bare `"99 "` does not match, so
/// "99 Luftballons" keeps its number.
private let trackNumberPrefixPattern = "^[0-9]{1,3}\\s*[-.)\\]]+\\s*"

/// Artist/title delimiters: ASCII hyphen, en dash, em dash — each surrounded by
/// single spaces (whitespace is already collapsed by this point).
private let artistTitleDelimiters = [" - ", " \u{2013} ", " \u{2014} "]
