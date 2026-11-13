// DownloadPasteInput — the pure, line-oriented front end of the paste flow.
//
// The paste sheet hands over free text, not URLs: a person pastes a block of links
// (one per line) that routinely carries blank lines, a stray sentence, or a link to
// something that is not YouTube at all. This type is the ONE place that text becomes
// a `[URL]` the queue will accept plus the LINES it refused — so the sheet can list
// what it skipped instead of silently dropping it, and so that decision is testable
// without a view, a process, or a network.
//
// It lives in `ViewModels` rather than the macOS shell because it is pure Foundation
// arithmetic over `YouTubeURLNormalizer` with no AppKit in sight, and because the
// paste report it feeds (``DownloadPasteReport``) is already here.
//
// LINE semantics, deliberately: the unit the sheet reports is a LINE, so a junk line
// of five words is ONE skipped entry rather than five. Splitting on whitespace would
// be more forgiving of a sloppy paste and would make the "skipped" list unreadable.
//
// This file imports only Foundation + Services; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant), nor URLSession or Process (the downloader
// boundary gate — `PlayerCore/Sources/ViewModels/Downloads` is scanned by
// `scripts/check-downloader-boundary.sh`).
import Foundation
import Services

/// One pasted block, split into the links the queue will take and the lines it won't.
public struct DownloadPasteInput: Sendable, Equatable, Hashable {
    /// The YouTube-family URLs, in paste order, ready for `enqueue(urls:)`.
    public let urls: [URL]
    /// The non-empty lines that named neither a video nor a playlist, verbatim, in
    /// paste order. Untranslatable content, so a call site renders `Text(verbatim:)`.
    public let skippedLines: [String]

    public init(urls: [URL], skippedLines: [String]) {
        self.urls = urls
        self.skippedLines = skippedLines
    }

    /// The input that carries nothing at all — an empty or whitespace-only paste.
    public static let empty = DownloadPasteInput(urls: [], skippedLines: [])

    /// Whether the paste produced neither a usable link nor a line worth reporting.
    public var isEmpty: Bool {
        urls.isEmpty && skippedLines.isEmpty
    }

    /// Splits `text` into accepted links and refused lines.
    ///
    /// A line is ACCEPTED when it parses as a URL that ``YouTubeURLNormalizer``
    /// resolves to a canonical video id, or that it classifies as a playlist link.
    /// Everything else non-blank is refused and reported. Blank lines are neither —
    /// a trailing newline is not a mistake anyone needs to be told about.
    public static func parse(_ text: String) -> DownloadPasteInput {
        var urls: [URL] = []
        var skipped: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let url = accepted(line) {
                urls.append(url)
            } else {
                skipped.append(line)
            }
        }
        return DownloadPasteInput(urls: urls, skippedLines: skipped)
    }

    /// The URL `line` names when the queue would actually take it, else `nil`.
    ///
    /// A YouTube URL that names NEITHER a video nor a playlist (a channel page, a
    /// `watch?v=` with a malformed id) is refused here rather than passed on: the
    /// queue would ignore it silently, and a silently-ignored link is exactly the
    /// thing the skipped list exists to prevent.
    private static func accepted(_ line: String) -> URL? {
        guard let url = URL(string: line), YouTubeURLNormalizer.isYouTubeURL(url) else { return nil }
        let namesVideo = YouTubeURLNormalizer.canonicalVideoID(from: url) != nil
        guard namesVideo || YouTubeURLNormalizer.isPlaylistURL(url) else { return nil }
        return url
    }
}

/// What one submitted paste did: the queue's own report, plus the lines that never
/// reached the queue.
///
/// ONE value for the same reason ``DownloadPasteReport`` is one struct: the sheet
/// tells the person "3 links added, 1 duplicate skipped, 1 line wasn't a YouTube
/// link" in a single sentence, and splitting the two halves would force it to
/// reassemble them anyway.
public struct DownloadPasteResult: Sendable, Equatable, Hashable {
    /// How many YouTube links the paste contained — the figure the report LEADS with.
    ///
    /// Distinct from ``DownloadPasteReport/added`` on purpose: a paste of three links
    /// one of which repeats reads "3 links, 1 duplicate skipped" and produces two rows,
    /// and leading with `added` would drop the arithmetic that explains the difference.
    public let linkCount: Int
    /// What the queue did with the links that reached it.
    public let report: DownloadPasteReport
    /// The lines ``DownloadPasteInput/parse(_:)`` refused, verbatim.
    public let skippedLines: [String]

    public init(linkCount: Int, report: DownloadPasteReport, skippedLines: [String]) {
        self.linkCount = linkCount
        self.report = report
        self.skippedLines = skippedLines
    }

    /// The result that changed nothing and had nothing to refuse.
    public static let zero = DownloadPasteResult(linkCount: 0, report: .zero, skippedLines: [])

    /// Whether the whole paste produced nothing worth reporting.
    public var isEmpty: Bool {
        linkCount == 0 && report.isEmpty && skippedLines.isEmpty
    }
}

public extension DownloadsViewModel {
    /// Parses `pastedText` and enqueues every YouTube link it found.
    ///
    /// The queue is NOT called at all when the paste yielded no link — an enqueue of
    /// an empty array is a no-op that would still cost a hop, and the sheet's report
    /// is the same either way.
    ///
    /// A playlist in the paste is expanded but HELD: the returned report carries a
    /// ``DownloadPasteReport/pendingPlaylist``, and nothing is queued for it until
    /// ``DownloadsViewModel/confirmPlaylist(_:)`` is called with that token.
    func submit(pastedText: String) async -> DownloadPasteResult {
        let input = DownloadPasteInput.parse(pastedText)
        guard !input.urls.isEmpty else {
            return DownloadPasteResult(linkCount: 0, report: .zero, skippedLines: input.skippedLines)
        }
        let report = await enqueue(urls: input.urls)
        return DownloadPasteResult(
            linkCount: input.urls.count,
            report: report,
            skippedLines: input.skippedLines
        )
    }
}
