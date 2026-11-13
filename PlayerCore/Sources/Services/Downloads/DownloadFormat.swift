// DownloadFormat — the download engine's format vocabulary, split into a STORAGE
// half and an ENGINE half.
//
// `DownloadAudioFormat` and `DownloadAudioQuality` are the STORAGE vocabulary: their
// `String` raw values are what settings persist, so they are frozen wire tokens —
// renaming a raw value silently invalidates every stored preference.
// `DownloadFormat` is the ENGINE vocabulary the queue and the argument builder speak.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit or Process
// (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// The container/codec a download is stored as — the STORAGE vocabulary.
///
/// Raw values are persisted in settings. They are a frozen wire format: add cases,
/// never rename an existing raw value.
public enum DownloadAudioFormat: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// AAC in an MP4 container. The default: YouTube serves it natively, so the
    /// download is a passthrough with no transcode (and no ffmpeg round-trip).
    case m4a
    /// MPEG-1 Layer III. Transcoded through ffmpeg.
    case mp3
    /// Opus in an Ogg container. Transcoded through ffmpeg.
    case opus
    /// Free Lossless Audio Codec. Transcoded through ffmpeg — lossless relative to
    /// the downloaded stream, which is itself lossy.
    case flac

    /// The format used when nothing is configured: native passthrough, no transcode.
    public static let `default`: DownloadAudioFormat = .m4a

    /// The file extension written to disk for this format.
    ///
    /// Identical to ``rawValue`` today; kept as a separate accessor so a future
    /// format whose extension differs from its token (e.g. `.ogg` for Vorbis) does
    /// not force the storage vocabulary to change.
    public var fileExtension: String {
        rawValue
    }

    /// Whether producing this format requires an ffmpeg transcode pass.
    ///
    /// `false` only for ``m4a``, which YouTube already serves natively.
    public var requiresTranscode: Bool {
        self != .m4a
    }
}

/// How aggressively the download engine should chase bitrate — the STORAGE vocabulary.
///
/// Raw values are persisted in settings; the mapping onto the engine's own
/// `--audio-quality` scale is owned by the argument builder, not by this type.
public enum DownloadAudioQuality: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// The best audio stream the source offers.
    case best
    /// A high-bitrate stream, trading a little fidelity for size.
    case high
    /// A mid-bitrate stream, prioritizing size.
    case medium

    /// The quality used when nothing is configured.
    public static let `default`: DownloadAudioQuality = .best
}

/// What a queued download produces — the video-extensible ENGINE vocabulary.
///
/// # Enum-vs-flat-keys coupling (read before adding a case)
/// This is an ENUM, while settings persist FLAT KEYS (one key for the audio format,
/// one for the audio quality). The two are deliberately coupled in one direction
/// only: **a future `.video(...)` case ADDS new storage keys; it never reshapes the
/// existing two.** Concretely, adding video support means introducing e.g.
/// `downloads.videoFormat` / `downloads.videoQuality` alongside — never instead of —
/// the audio keys, and leaving `DownloadAudioFormat`/`DownloadAudioQuality` raw
/// values untouched. That keeps every already-persisted audio preference readable by
/// the version that ships video, and keeps this enum free to grow without a settings
/// migration. Reshaping the audio keys to accommodate a video case is the one change
/// this design forbids.
///
/// The UI ships audio-only; the model is extensible so the engine protocol, the queue
/// records, and the argument builder do not have to be re-typed later.
public enum DownloadFormat: Sendable, Equatable, Hashable {
    /// Extract audio only, in the given container at the given quality.
    case audio(DownloadAudioFormat, DownloadAudioQuality)

    /// The format used when nothing is configured: native-passthrough m4a at best quality.
    public static let `default`: DownloadFormat = .audio(.default, .default)

    /// The audio container this format writes, for every case that produces audio.
    public var audioFormat: DownloadAudioFormat {
        switch self {
        case let .audio(format, _): format
        }
    }

    /// The requested audio quality, for every case that produces audio.
    public var audioQuality: DownloadAudioQuality {
        switch self {
        case let .audio(_, quality): quality
        }
    }

    /// The file extension the finished download is written with.
    public var fileExtension: String {
        switch self {
        case let .audio(format, _): format.fileExtension
        }
    }
}
