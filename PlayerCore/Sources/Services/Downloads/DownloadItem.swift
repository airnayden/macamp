// DownloadItem / DownloadState — one row of the download queue and its lifecycle.
//
// A `DownloadItem` is created the moment a URL is accepted, from nothing but the
// canonical video id and the source URL. The descriptive fields (title, uploader,
// duration, thumbnail) are OPTIONAL and filled LAZILY by the metadata prefetch, so a
// row can render immediately and enrich itself in place — the queue never blocks on
// metadata to show progress.
//
// Identity is the `id` (a per-enqueue `UUID`), NOT the video id: the same video may
// legitimately be queued twice after the first attempt was cancelled. Dedup is a
// queue policy keyed on ``canonicalVideoID``, deliberately separate from identity.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit or Process
// (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Where a queued download currently is in its lifecycle.
///
/// The progress payload rides on ``downloading(fraction:speedBytesPerSec:etaSeconds:)``
/// rather than living beside the state, so an observer can never read a stale
/// fraction against a newer state. `speedBytesPerSec` and `etaSeconds` are optional
/// because the engine omits them for the first samples and for unsized streams.
public enum DownloadState: Sendable, Equatable, Hashable {
    /// Accepted into the queue, waiting for the serial driver to pick it up.
    case queued
    /// The engine is prefetching title/uploader/duration/thumbnail.
    case fetchingMetadata
    /// Bytes are moving. `fraction` is `0...1`.
    case downloading(fraction: Double, speedBytesPerSec: Int64?, etaSeconds: Int?)
    /// The transfer finished; the engine is extracting/transcoding/tagging.
    ///
    /// `fraction` is `nil` for the WHOLE phase unless ffmpeg is actually emitting
    /// `-progress` samples for the extraction pass AND the video's duration is known.
    /// It goes back to `nil` at the terminal `progress=end`, because the embed and
    /// metadata passes still run after that and a bar pinned at 100% through them is the
    /// dishonesty this payload exists to remove. A fraction is never estimated,
    /// interpolated, or advanced by a timer — no samples means `nil`.
    case postProcessing(fraction: Double?)
    /// The finished file landed at `fileURL` in the destination folder.
    case finished(fileURL: URL)
    /// The download stopped with a typed failure.
    case failed(DownloadError)
    /// The download was cancelled (by the person or by a queue-wide cancel).
    case cancelled

    /// Whether this state is terminal — the driver will not advance it further.
    public var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled: true
        case .queued, .fetchingMetadata, .downloading, .postProcessing: false
        }
    }

    /// Whether the serial driver currently has this item in flight.
    public var isActive: Bool {
        switch self {
        case .fetchingMetadata, .downloading, .postProcessing: true
        case .queued, .finished, .failed, .cancelled: false
        }
    }

    /// The completion fraction to render, in `0...1`.
    ///
    /// Indeterminate phases report `nil` (the UI shows an indeterminate indicator);
    /// terminal success reports `1`. `fraction` is clamped, so a malformed engine
    /// sample can never drive a progress bar out of range.
    ///
    /// Post-processing is the one phase that reports BOTH over its lifetime: `nil` until
    /// a real ffmpeg sample arrives, the sample while they keep arriving, and `nil` again
    /// from `progress=end`. Only the bar's determinacy follows it — the row's caption
    /// names the phase and must not change with it.
    public var fraction: Double? {
        switch self {
        case let .downloading(fraction, _, _): min(max(fraction, 0), 1)
        case let .postProcessing(fraction): fraction.map { min(max($0, 0), 1) }
        case .finished: 1
        case .queued, .fetchingMetadata, .failed, .cancelled: nil
        }
    }

    /// The typed failure when this state is ``failed(_:)``, otherwise `nil`.
    public var error: DownloadError? {
        guard case let .failed(error) = self else { return nil }
        return error
    }
}

/// One row of the download queue: a canonical video plus its lazily-enriched metadata.
public struct DownloadItem: Sendable, Equatable, Hashable, Identifiable {
    /// This enqueue's identity. Stable for the row's whole lifetime; NOT the video id
    /// (the same video can be queued again after a cancel).
    public let id: UUID
    /// The 11-character canonical YouTube video id, resolved by ``YouTubeURLNormalizer``.
    /// Dedup and the destination filename both key on this.
    public let canonicalVideoID: String
    /// The URL the person actually pasted, kept verbatim for display and retry.
    public let sourceURL: URL
    /// The video title. `nil` until the metadata prefetch fills it.
    public var title: String?
    /// The channel/uploader name. `nil` until the metadata prefetch fills it.
    public var uploader: String?
    /// The video duration in seconds. `nil` until the metadata prefetch fills it.
    public var durationSeconds: Int?
    /// The thumbnail URL. `nil` until the metadata prefetch fills it.
    public var thumbnailURL: URL?
    /// The format this row was actually dequeued with, stamped by the driver at the
    /// moment it read the setting.
    ///
    /// `nil` until then, and it stays the value the row RAN with: the configured format
    /// is read per dequeue, so a settings change while this row is in flight applies to
    /// the next row rather than rewriting this one's history. A finished row therefore
    /// reports the container it actually produced, not whatever the setting says later.
    public var resolvedFormat: DownloadFormat?
    /// Where this row is in its lifecycle.
    public var state: DownloadState

    public init(
        id: UUID = UUID(),
        canonicalVideoID: String,
        sourceURL: URL,
        title: String? = nil,
        uploader: String? = nil,
        durationSeconds: Int? = nil,
        thumbnailURL: URL? = nil,
        resolvedFormat: DownloadFormat? = nil,
        state: DownloadState = .queued
    ) {
        self.id = id
        self.canonicalVideoID = canonicalVideoID
        self.sourceURL = sourceURL
        self.title = title
        self.uploader = uploader
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.resolvedFormat = resolvedFormat
        self.state = state
    }

    /// The best label available right now: the fetched title, else the canonical id.
    ///
    /// Returns a plain `String` on purpose — every value it can return is untranslatable
    /// content (a video title or an id), so the call site renders it with
    /// `Text(verbatim:)`.
    public var displayTitle: String {
        title ?? canonicalVideoID
    }
}
