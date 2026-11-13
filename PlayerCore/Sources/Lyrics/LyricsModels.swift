import Foundation

/// A single timed word within a karaoke-style lyric line (enhanced `.lrc` `<mm:ss.xx>`).
public struct TimedWord: Equatable, Sendable, Codable {
    /// Absolute playback time (seconds) at which this word becomes active.
    public var time: TimeInterval
    /// The word (or fragment) text, including any trailing whitespace as authored.
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

/// A single line of lyrics. `time == nil` denotes an unsynced (plain) line.
public struct LyricLine: Equatable, Sendable, Codable {
    /// Absolute playback time (seconds) at which this line becomes active, or `nil` if unsynced.
    public var time: TimeInterval?
    /// The full plain text of the line.
    public var text: String
    /// Optional per-word timings for karaoke highlighting (enhanced `.lrc`).
    public var words: [TimedWord]?

    public init(time: TimeInterval? = nil, text: String, words: [TimedWord]? = nil) {
        self.time = time
        self.text = text
        self.words = words
    }

    /// True when this line carries a line-level timestamp.
    public var isSynced: Bool {
        time != nil
    }
}

/// Origin of a resolved lyrics payload, in precedence order of trust.
public enum LyricsSource: String, Equatable, Sendable, Codable, CaseIterable {
    /// Embedded synced lyrics (e.g. ID3 SYLT).
    case embeddedSynced
    /// Sidecar `.lrc` file next to the audio file.
    case lrcFile
    /// Fetched from the LRCLIB online service (opt-in only).
    case lrclib
    /// Embedded unsynced lyrics (e.g. ID3 USLT, plain text).
    case embeddedUnsynced

    /// Higher rank wins precedence. Mirrors documented resolution order.
    public var precedenceRank: Int {
        switch self {
        case .embeddedSynced: 3
        case .lrcFile: 2
        case .lrclib: 1
        case .embeddedUnsynced: 0
        }
    }
}

/// A fully resolved lyrics document for a track.
public struct Lyrics: Equatable, Sendable, Codable {
    /// Lines in display order. For synced lyrics these are sorted ascending by `time`.
    public var lines: [LyricLine]
    /// Where these lyrics came from.
    public var source: LyricsSource
    /// Parsed metadata tags from `.lrc` (`ar`, `ti`, `al`, …). May be empty.
    public var metadata: [String: String]
    /// Global offset (seconds) already folded into `lines` timing; retained for reference.
    public var offset: TimeInterval

    public init(
        lines: [LyricLine],
        source: LyricsSource,
        metadata: [String: String] = [:],
        offset: TimeInterval = 0
    ) {
        self.lines = lines
        self.source = source
        self.metadata = metadata
        self.offset = offset
    }

    /// True when at least one line carries a timestamp (line- or word-level).
    public var isSynced: Bool {
        lines.contains { $0.time != nil || ($0.words?.isEmpty == false) }
    }

    /// True when there are no lines at all.
    public var isEmpty: Bool {
        lines.isEmpty
    }

    /// All line texts joined by newlines (plain rendering).
    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}
