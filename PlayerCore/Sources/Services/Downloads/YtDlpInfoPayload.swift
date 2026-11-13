// YtDlpInfoPayload — the reading half of the engine's `-J` info document.
//
// `YtDlpProgressParser` reads the engine's LINE-oriented sentinels; this type reads its
// other machine-readable interface, the single JSON document `-J` prints. Both are
// deliberately kept out of the queue service itself, so the wire formats stay pure,
// exhaustively table-testable, and free of any queue state.
//
// # One type answers both prefetch questions
// `--flat-playlist -J` returns the SAME document shape for a playlist and for a single
// video — a playlist just carries an `entries` array of the same objects. Modelling that
// with one recursive struct is what lets playlist expansion and the per-item lazy
// metadata fetch share a single spawn helper instead of two near-identical decoders.
//
// # Everything is optional, and nulls are tolerated
// The engine omits fields it could not resolve, renames some between releases
// (`uploader` vs `channel`), writes `duration` as a FLOAT, and writes a literal `null`
// entry for a video that has been removed from a playlist. None of that may fail a
// paste: an undecodable field degrades to `nil`, and a `null` entry is skipped. Metadata
// is decorative here — the download only ever needs the canonical id.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// One node of the engine's `-J` info document: a video, or a playlist carrying videos.
public struct YtDlpInfoPayload: Decodable, Sendable, Equatable, Hashable {
    /// The canonical video id, for a node that names a video.
    public let id: String?
    /// The video (or playlist) title.
    public let title: String?
    /// The channel name under the field the engine has used the longest.
    public let uploader: String?
    /// The channel name under the field newer engine builds prefer.
    public let channel: String?
    /// Duration in seconds. A `Double` because the engine writes fractional values.
    public let duration: Double?
    /// The chosen thumbnail, when the engine resolved one.
    public let thumbnail: String?
    /// A playlist's entries. Optional elements: a removed video is a literal `null`.
    public let entries: [YtDlpInfoPayload?]?

    public init(
        id: String? = nil,
        title: String? = nil,
        uploader: String? = nil,
        channel: String? = nil,
        duration: Double? = nil,
        thumbnail: String? = nil,
        entries: [YtDlpInfoPayload?]? = nil
    ) {
        self.id = id
        self.title = title
        self.uploader = uploader
        self.channel = channel
        self.duration = duration
        self.thumbnail = thumbnail
        self.entries = entries
    }

    /// The channel name to display: whichever field this engine build populated.
    public var uploaderName: String? {
        let candidate = uploader ?? channel
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
    }

    /// The title to display, or `nil` when the engine reported none it could use.
    ///
    /// The EMPTY string is folded into `nil` deliberately, exactly as ``uploaderName``
    /// folds an empty channel. A caller writes this over a title the person may already
    /// be reading (the paste-time oEmbed decoration), and `""` is not an improvement on
    /// anything — it would blank the row's label, since ``DownloadItem/displayTitle``
    /// falls back to the canonical id only for `nil`.
    public var titleText: String? {
        guard let title, !title.isEmpty else { return nil }
        return title
    }

    /// The duration in whole seconds, or `nil` when the engine reported none.
    ///
    /// Goes through `Int(exactly:)` on a rounded value because a direct `Int(Double)`
    /// TRAPS on NaN, infinity, and out-of-range — a hostile document must degrade to
    /// `nil`, never crash the driver.
    public var durationSeconds: Int? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        return Int(exactly: duration.rounded())
    }

    /// The thumbnail as a URL, when the engine reported a usable one.
    public var thumbnailURL: URL? {
        guard let thumbnail, !thumbnail.isEmpty else { return nil }
        return URL(string: thumbnail)
    }

    /// One queueable video this document names: its canonical id plus whatever
    /// descriptive fields the SAME document already carried for it.
    ///
    /// `--flat-playlist -J` prints a title (and often a channel) per entry, so a
    /// playlist expansion can stamp its rows from the document it already paid for —
    /// zero extra requests, zero extra spawns.
    public struct VideoEntry: Sendable, Equatable, Hashable {
        public let videoID: String
        public let title: String?
        public let uploaderName: String?
        public let thumbnailURL: URL?

        public init(videoID: String, title: String?, uploaderName: String?, thumbnailURL: URL?) {
            self.videoID = videoID
            self.title = title
            self.uploaderName = uploaderName
            self.thumbnailURL = thumbnailURL
        }
    }

    /// The queueable videos this document names, in document order.
    ///
    /// A playlist yields its entries; a single video yields itself. Duplicate and
    /// malformed ids are dropped, so the caller receives a list it can queue verbatim.
    public var videoEntries: [VideoEntry] {
        guard let entries else {
            return validVideoID(id).map { [entry(from: self, videoID: $0)] } ?? []
        }
        var seen = Set<String>()
        var result: [VideoEntry] = []
        for candidate in entries {
            guard let candidate,
                  let videoID = validVideoID(candidate.id),
                  seen.insert(videoID).inserted
            else { continue }
            result.append(entry(from: candidate, videoID: videoID))
        }
        return result
    }

    /// The canonical video ids this document names, in document order.
    ///
    /// Derived from ``videoEntries`` rather than walking the document a second time, so
    /// "which videos" has exactly one definition and the two can never disagree.
    public var videoIDs: [String] {
        videoEntries.map(\.videoID)
    }

    /// Decodes the document the engine printed across `lines`, or `nil` when those lines
    /// are not one.
    ///
    /// The lines are joined rather than searched: `-J` prints exactly one document, and
    /// joining keeps a (theoretical) pretty-printed document decodable while a
    /// line-by-line search would find only fragments.
    public static func decode(from lines: [String]) -> YtDlpInfoPayload? {
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty, let data = joined.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(YtDlpInfoPayload.self, from: data)
    }
}

private extension YtDlpInfoPayload {
    /// `candidate` when it has the exact shape of a YouTube video id, else `nil`.
    func validVideoID(_ candidate: String?) -> String? {
        guard let candidate, YouTubeURLNormalizer.isValidVideoID(candidate) else { return nil }
        return candidate
    }

    func entry(from node: YtDlpInfoPayload, videoID: String) -> VideoEntry {
        VideoEntry(
            videoID: videoID,
            title: node.titleText,
            uploaderName: node.uploaderName,
            thumbnailURL: node.thumbnailURL
        )
    }
}
