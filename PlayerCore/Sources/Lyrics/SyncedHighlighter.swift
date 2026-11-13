import Foundation

/// Resolves the active lyric line (and word) for a given playback time using a
/// binary search over sorted timestamps — the engine behind a karaoke-style UI.
///
/// The highlighter keeps only the *timed* lines, sorted ascending by time, so
/// `activeLineIndex(at:)` is an `O(log n)` lookup suitable for a 60 fps redraw.
/// Indices returned by this type are into ``lines`` (the timed-only, sorted view).
public struct SyncedHighlighter: Sendable {
    /// The timed lines, sorted ascending by ``LyricLine/time``.
    public let lines: [LyricLine]

    /// Parallel array of line start times (seconds), aligned with ``lines``.
    private let times: [TimeInterval]

    /// Builds a highlighter from a resolved ``Lyrics`` document.
    public init(_ lyrics: Lyrics) {
        self.init(lines: lyrics.lines)
    }

    /// Builds a highlighter from raw lines, keeping only the timed ones (sorted).
    public init(lines: [LyricLine]) {
        let timed = lines
            .filter { $0.time != nil }
            .sorted { ($0.time ?? 0) < ($1.time ?? 0) }
        self.lines = timed
        times = timed.map { $0.time ?? 0 }
    }

    /// `true` when there are no timed lines to highlight.
    public var isEmpty: Bool {
        lines.isEmpty
    }

    /// The index (into ``lines``) of the line active at `time`, or `nil` when the
    /// playhead is before the first line.
    public func activeLineIndex(at time: TimeInterval) -> Int? {
        Self.lastIndex(in: times, notAfter: time)
    }

    /// The line active at `time`, or `nil` when the playhead is before the first line.
    public func activeLine(at time: TimeInterval) -> LyricLine? {
        guard let index = activeLineIndex(at: time) else { return nil }
        return lines[index]
    }

    /// The index of the active word within the line at `lineIndex`, or `nil` when
    /// the line has no per-word timings or the playhead precedes its first word.
    public func activeWordIndex(at time: TimeInterval, inLineAt lineIndex: Int) -> Int? {
        guard lines.indices.contains(lineIndex),
              let words = lines[lineIndex].words, !words.isEmpty else { return nil }
        let wordTimes = words.map(\.time)
        return Self.lastIndex(in: wordTimes, notAfter: time)
    }

    /// The active line and (optional) word position at `time`.
    public func activePosition(at time: TimeInterval) -> ActivePosition? {
        guard let lineIndex = activeLineIndex(at: time) else { return nil }
        let wordIndex = activeWordIndex(at: time, inLineAt: lineIndex)
        return ActivePosition(lineIndex: lineIndex, wordIndex: wordIndex)
    }

    /// Binary search for the rightmost index whose value is `<= time`, or `nil`
    /// when `time` is before the first element (or the array is empty).
    private static func lastIndex(in times: [TimeInterval], notAfter time: TimeInterval) -> Int? {
        guard let first = times.first, time >= first else { return nil }
        var low = 0
        var high = times.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if times[mid] <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

/// The active highlight position: a line index plus an optional word index.
public struct ActivePosition: Equatable, Sendable {
    /// Index into ``SyncedHighlighter/lines`` of the active line.
    public let lineIndex: Int
    /// Index into the line's `words`, or `nil` when the line is not word-timed.
    public let wordIndex: Int?

    public init(lineIndex: Int, wordIndex: Int?) {
        self.lineIndex = lineIndex
        self.wordIndex = wordIndex
    }
}
