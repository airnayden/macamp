import Foundation

/// A dependency-free parser for the `.lrc` lyric format, including the *enhanced*
/// variant that carries per-word timings as `<mm:ss.xx>` markers.
///
/// The parser is implemented as a manual character scan (no `NSRegularExpression`,
/// no `Regex`, no force-unwraps) so it stays `Sendable`-clean and portable. It
/// understands:
///
/// * line timestamps `[mm:ss.xx]` (one or more leading tags share the same text),
/// * enhanced word timings `<mm:ss.xx>word`,
/// * metadata tags `[ar:]`, `[ti:]`, `[al:]`, `[by:]`, `[length:]`, …, and
/// * the global `[offset:±ms]` tag, folded into every timestamp.
///
/// ### Offset convention
/// Per the LRC specification a **positive** offset makes lyrics appear *earlier*,
/// so the parser stores `adjustedTime = rawTime - offsetSeconds`. The applied
/// offset (in seconds) is also surfaced on ``Lyrics/offset`` for reference.
public enum LRCParser {
    /// Parses `.lrc` `content` into a ``Lyrics`` document.
    ///
    /// - Parameters:
    ///   - content: The raw `.lrc` text.
    ///   - source: The origin to stamp on the result (defaults to ``LyricsSource/lrcFile``).
    /// - Returns: A ``Lyrics`` value with synced lines sorted ascending by time.
    public static func parse(_ content: String, source: LyricsSource = .lrcFile) -> Lyrics {
        var context = ParseContext()
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            context.ingest(line: line)
        }
        return context.makeLyrics(source: source)
    }

    /// Reports whether `text` contains at least one `[mm:ss]`-style timestamp tag.
    ///
    /// Used to classify embedded lyric blobs as synced vs. unsynced.
    public static func containsTimestamps(_ text: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if chars[index] == "[",
               let close = indexOfClosing(chars, from: index, closing: "]"),
               parseTimestamp(String(chars[(index + 1) ..< close])) != nil
            {
                return true
            }
            index += 1
        }
        return false
    }
}

// MARK: - Parse state

private extension LRCParser {
    /// A raw synced line before the global offset is folded in.
    struct RawSyncedLine {
        let time: TimeInterval
        let text: String
        let words: [TimedWord]?
    }

    /// Accumulates parser state across the lines of one `.lrc` document.
    struct ParseContext {
        var metadata: [String: String] = [:]
        var offsetSeconds: TimeInterval = 0
        var synced: [RawSyncedLine] = []
        var unsynced: [LyricLine] = []

        mutating func ingest(line: String) {
            let (tags, rest) = LRCParser.extractLeadingTags(line)
            guard !tags.isEmpty else {
                unsynced.append(LyricLine(text: line))
                return
            }
            var timestamps: [TimeInterval] = []
            for tag in tags {
                if let time = LRCParser.parseTimestamp(tag) {
                    timestamps.append(time)
                } else {
                    applyMetadata(tag)
                }
            }
            guard !timestamps.isEmpty else { return }
            let (plain, words) = LRCParser.parseWordTimings(rest)
            for time in timestamps {
                synced.append(RawSyncedLine(time: time, text: plain, words: words))
            }
        }

        mutating func applyMetadata(_ tag: String) {
            guard let colon = tag.firstIndex(of: ":") else { return }
            let key = String(tag[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(tag[tag.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            metadata[key] = value
            if key == "offset", let millis = Double(value) {
                offsetSeconds = millis / 1000.0
            }
        }

        func makeLyrics(source: LyricsSource) -> Lyrics {
            let offset = offsetSeconds
            var lines = synced.map { entry -> LyricLine in
                let words = entry.words?.map { TimedWord(time: $0.time - offset, text: $0.text) }
                return LyricLine(time: entry.time - offset, text: entry.text, words: words)
            }
            lines.sort { ($0.time ?? 0) < ($1.time ?? 0) }
            lines.append(contentsOf: unsynced)
            return Lyrics(lines: lines, source: source, metadata: metadata, offset: offset)
        }
    }
}

// MARK: - Scanning primitives

private extension LRCParser {
    /// Extracts the run of leading `[...]` tags and returns them with the remaining text.
    static func extractLeadingTags(_ line: String) -> (tags: [String], rest: String) {
        let chars = Array(line)
        var tags: [String] = []
        var index = 0
        while index < chars.count, chars[index] == "[" {
            guard let close = indexOfClosing(chars, from: index, closing: "]") else { break }
            tags.append(String(chars[(index + 1) ..< close]))
            index = close + 1
        }
        let rest = index < chars.count ? String(chars[index...]) : ""
        return (tags, rest)
    }

    /// Splits enhanced-LRC `text` into its plain form (markers stripped) and the
    /// per-word timings. Returns `nil` words when no `<…>` markers are present.
    static func parseWordTimings(_ text: String) -> (plain: String, words: [TimedWord]?) {
        guard text.contains("<") else { return (text, nil) }
        let chars = Array(text)
        var plain = ""
        var words: [TimedWord] = []
        var pendingTime: TimeInterval?
        var segment = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "<",
               let close = indexOfClosing(chars, from: index, closing: ">"),
               let time = parseTimestamp(String(chars[(index + 1) ..< close]))
            {
                if let previous = pendingTime {
                    words.append(TimedWord(time: previous, text: segment))
                }
                pendingTime = time
                segment = ""
                index = close + 1
                continue
            }
            plain.append(chars[index])
            if pendingTime != nil {
                segment.append(chars[index])
            }
            index += 1
        }
        if let previous = pendingTime {
            words.append(TimedWord(time: previous, text: segment))
        }
        return (plain, words.isEmpty ? nil : words)
    }

    /// Finds the index of the next `closing` character after `start`.
    static func indexOfClosing(_ chars: [Character], from start: Int, closing: Character) -> Int? {
        var index = start + 1
        while index < chars.count {
            if chars[index] == closing { return index }
            index += 1
        }
        return nil
    }

    /// Parses a `mm:ss(.ff)` or `hh:mm:ss(.ff)` timestamp into seconds, or `nil`.
    static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isNumber else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        if parts.count == 3 {
            guard let hours = Double(parts[0]) else { return nil }
            total += hours * 3600
        }
        guard let minutes = Double(parts[parts.count - 2]),
              let seconds = parseSeconds(String(parts[parts.count - 1])) else { return nil }
        total += minutes * 60 + seconds
        return total
    }

    /// Parses a `ss` or `ss.ff` seconds component, honouring the fraction width.
    static func parseSeconds(_ component: String) -> Double? {
        let parts = component.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 1 {
            return Double(parts[0])
        }
        guard parts.count == 2, !parts[1].isEmpty,
              let whole = Double(parts[0].isEmpty ? "0" : String(parts[0])),
              let fraction = Double(parts[1]) else { return nil }
        let denominator = pow(10.0, Double(parts[1].count))
        return whole + fraction / denominator
    }
}
