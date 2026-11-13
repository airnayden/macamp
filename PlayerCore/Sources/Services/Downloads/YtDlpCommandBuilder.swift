// YtDlpCommandBuilder — pure composition of the engine's argument vectors.
//
// Nothing here spawns anything: the builder turns a request value into a `[String]`
// and stops. That is what makes the whole command surface a GOLDEN-ARRAY test rather
// than an integration test — every flag MacAMP will ever pass is asserted byte for
// byte, offline, in milliseconds.
//
// # Three flags that look optional and are not
// - `--progress` is MANDATORY. `--print` implies `--quiet`, and `--quiet` suppresses
//   the progress reporter outright; only `--progress` forces it back on. Without it the
//   `MACAMP-P`/`MACAMP-PP` sentinel lines are never emitted at all — and a golden-array
//   test cannot catch its absence, because the array would still look plausible. It is
//   pinned here, unconditionally, for exactly that reason.
// - `--embed-thumbnail` is UNCONDITIONAL. The PyInstaller engine binary bundles
//   mutagen, which embeds m4a/mp3 cover art without needing AtomicParsley on the
//   machine, so there is no capability to probe and no reason to make it a setting.
// - `--ignore-config` + `--no-config-locations` are what stop a stray user config file
//   from rewriting MacAMP's arguments behind its back. The child environment is also
//   sanitized of `YTDLP_CONFIG_HOME` and friends by the process runner (todo 8) — the
//   two halves together are the guarantee.
//
// `-U` / `--update-to` is NEVER emitted from anywhere in this file. Engine updates are
// a separate, explicit, user-initiated flow; a download must never mutate the tool it
// is running.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate).
import Foundation

/// Everything one download needs, as a value.
///
/// A struct rather than five loose parameters: the three directories are easy to
/// transpose at a call site, and a named field makes that mistake visible in review.
public struct YtDlpDownloadRequest: Sendable, Equatable, Hashable {
    /// The canonical 11-character video id. The final watch URL is REBUILT from this,
    /// never carried over from the person's paste — see ``YtDlpCommandBuilder/watchURL(forVideoID:)``.
    public let videoID: String
    /// What the download produces (container + quality).
    public let format: DownloadFormat
    /// Where the finished file lands (`-P home:`).
    public let downloadsDirectory: URL
    /// Where partial files live while the transfer runs (`-P temp:`).
    public let stagingDirectory: URL
    /// The directory holding the bundled `ffmpeg`/`ffprobe`, and the parent of the
    /// engine's own cache directory.
    public let toolsDirectory: URL

    public init(
        videoID: String,
        format: DownloadFormat,
        downloadsDirectory: URL,
        stagingDirectory: URL,
        toolsDirectory: URL
    ) {
        self.videoID = videoID
        self.format = format
        self.downloadsDirectory = downloadsDirectory
        self.stagingDirectory = stagingDirectory
        self.toolsDirectory = toolsDirectory
    }
}

/// Builds the exact argument vectors MacAMP hands the download engine.
public enum YtDlpCommandBuilder {
    /// The output filename template. `%(id)s` is in the name on purpose: it is what
    /// keeps two videos that share a title from colliding in the destination folder.
    public static let outputTemplate = "%(title)s [%(id)s].%(ext)s"

    /// The engine cache directory's name inside the tools directory. Pinned so the
    /// cache never lands in the person's home directory or inside the app bundle.
    public static let cacheDirectoryName = "yt-dlp-cache"

    /// The `download:` progress template. Every field is `%(progress.…)s` so an
    /// unavailable value arrives as `NA` rather than collapsing the line's shape.
    public static let downloadProgressTemplate = "download:" + YtDlpSentinel.progress
        + "%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s"
        + "|%(progress.total_bytes_estimate)s|%(progress.eta)s|%(progress.speed)s"

    /// The `postprocess:` progress template — status plus which post-processor is running.
    public static let postProcessProgressTemplate = "postprocess:" + YtDlpSentinel.postProcess
        + "%(progress.status)s|%(progress.postprocessor)s"

    /// The `after_move:` print template — the ONLY authoritative source of the finished
    /// file's path. `after_move` (not `filepath`) is what reports the path AFTER the
    /// post-processors have renamed and moved the file into the destination folder.
    public static let filePathPrintTemplate = "after_move:" + YtDlpSentinel.filePath + "%(filepath)s"

    /// The leading half of the conversion progress file's name.
    ///
    /// Carries a TRAILING SPACE so the name reads `ffprogress [<id>].txt`. That space is
    /// half of why the value below has to be quoted — see ``postProcessorArguments(for:)``.
    public static let ffProgressNamePrefix = "ffprogress "

    /// The conversion progress file's extension. `.txt` rather than a bespoke suffix so
    /// a person who opens the staging directory can see what it is.
    public static let ffProgressNameSuffix = ".txt"

    /// The name of the file ffmpeg writes its `-progress` blocks into for `videoID`.
    ///
    /// Built from ``DownloadStagingSweeper/artifactMarker(forVideoID:)`` rather than
    /// re-spelling `[` + id + `]` here, so the per-item staging purge and this name
    /// cannot drift apart: whatever the purge matches on is literally what this emits.
    /// One file per video is sufficient because the queue dedups on the canonical id, so
    /// the same video can never be in flight twice at once.
    public static func ffProgressFileName(forVideoID videoID: String) -> String {
        ffProgressNamePrefix + DownloadStagingSweeper.artifactMarker(forVideoID: videoID) + ffProgressNameSuffix
    }

    /// Where ffmpeg's `-progress` blocks for `videoID` land inside `stagingDirectory`.
    ///
    /// The STAGING directory, never the destination: this file is engine bookkeeping and
    /// must never appear in the listener's music folder, and putting it here is also what
    /// makes the launch sweep and the per-item purge able to reclaim it.
    public static func ffProgressURL(forVideoID videoID: String, in stagingDirectory: URL) -> URL {
        stagingDirectory.appending(path: ffProgressFileName(forVideoID: videoID))
    }

    /// The arguments that expand a playlist URL into its entries, as JSON on stdout.
    ///
    /// `--flat-playlist` is what keeps this cheap: the engine lists entries without
    /// resolving each video's formats, so a 500-entry playlist costs one request rather
    /// than 500. `-J` asks for a single JSON document; `--no-warnings` and `--no-color`
    /// keep that document the only thing on the stream.
    public static func prefetchArguments(for url: URL) -> [String] {
        [
            "--flat-playlist",
            "-J",
            "--no-warnings",
            "--ignore-config",
            "--no-config-locations",
            "--no-color",
            url.absoluteString,
        ]
    }

    /// The canonical watch URL for a flat-playlist entry, built from its `id` field.
    ///
    /// # Read the `id`, never the `url`
    /// A flat playlist entry carries both. The `url` field is whatever the listing
    /// happened to contain — it can arrive relative, shortened, or still carrying the
    /// playlist's own `&list=`/`&index=` context, and passing it through would make one
    /// pasted playlist re-expand into itself on every entry. Rebuilding from the bare
    /// id is what actually strips that noise, and it is the same rebuild the single
    /// video path performs, so both paths hand the engine an identical URL shape.
    ///
    /// - Returns: `nil` when `videoID` is not a well-formed id.
    public static func watchURL(forVideoID videoID: String) -> URL? {
        YouTubeURLNormalizer.canonicalURL(forVideoID: videoID)
    }

    /// The full argument vector for one download, or `nil` when `request.videoID` is
    /// not a well-formed video id.
    ///
    /// The order is pinned: it is asserted byte for byte by the golden-array tests, so
    /// a reordering is a test failure rather than a silent behavior change.
    public static func downloadArguments(for request: YtDlpDownloadRequest) -> [String]? {
        guard let watchURL = watchURL(forVideoID: request.videoID) else { return nil }
        return reportingArguments
            + audioArguments(for: request.format)
            + destinationArguments(for: request)
            + [watchURL.absoluteString]
    }
}

// MARK: - Argument groups

private extension YtDlpCommandBuilder {
    /// Config isolation, line-oriented output, and the three machine-readable templates.
    static var reportingArguments: [String] {
        [
            "--ignore-config",
            "--no-config-locations",
            "--no-color",
            "--newline",
            "--progress",
            "--no-playlist",
            "--progress-template", downloadProgressTemplate,
            "--progress-template", postProcessProgressTemplate,
            "--print", filePathPrintTemplate,
        ]
    }

    /// Audio extraction: container, optional quality, and the two embed passes.
    ///
    /// `--audio-quality` and its value are emitted TOGETHER or not at all — a lossless
    /// format has no quality argument, and a bare flag with no value would be a parse
    /// error at the engine rather than a default.
    static func audioArguments(for format: DownloadFormat) -> [String] {
        let audioFormat = format.audioFormat
        let quality = YtDlpArgumentTables.audioQualityArgument(
            format: audioFormat,
            quality: format.audioQuality
        )
        let qualityArguments = quality.map { ["--audio-quality", $0] } ?? []
        return ["-x", "--audio-format", audioFormat.rawValue]
            + qualityArguments
            + ["--embed-thumbnail", "--embed-metadata"]
    }

    /// Where files land, what they are called, and where the engine's helpers live.
    static func destinationArguments(for request: YtDlpDownloadRequest) -> [String] {
        let cacheDirectory = request.toolsDirectory.appending(path: cacheDirectoryName)
        return [
            "-P", "home:" + path(of: request.downloadsDirectory),
            "-P", "temp:" + path(of: request.stagingDirectory),
            "-o", outputTemplate,
            "--ffmpeg-location", path(of: request.toolsDirectory),
            "--cache-dir", path(of: cacheDirectory),
        ] + postProcessorArguments(for: request)
    }

    /// Asks the EXTRACTION ffmpeg — and only that one — to write machine-readable
    /// progress blocks, so a transcode can report a real fraction instead of a spinner.
    ///
    /// # The quotes are load-bearing, not defensive
    /// yt-dlp `shlex.split`s everything after the `NAME+EXE:` prefix of a
    /// `--postprocessor-args` value, and BOTH halves of the path it is handed contain
    /// whitespace on a stock install: the staging directory is
    /// `~/Library/Application Support/MacAMP/Downloads-Staging` and the file itself is
    /// `ffprogress [<id>].txt`. Unquoted, the splitter hands ffmpeg
    /// `-progress`, `/Users/…/Application`, `Support/…`, `[<id>].txt` — which ffmpeg
    /// reads as OUTPUT FILES and rejects with `Error opening output files: Invalid
    /// argument`, failing EVERY download on a default configuration (measured, todo 8:
    /// unquoted exit 1 and no file, quoted exit 0 with samples). The quotes are literal
    /// characters inside this one argument element; the element reaches the engine
    /// through `Process.arguments`, so no shell ever consumes them and they arrive
    /// intact at yt-dlp's own splitter.
    ///
    /// Scoped to `ExtractAudio` so the later `EmbedThumbnail`/`Metadata` ffmpeg passes —
    /// which run AFTER the terminal `progress=end` — never reopen and truncate the file.
    static func postProcessorArguments(for request: YtDlpDownloadRequest) -> [String] {
        let progressFile = ffProgressURL(forVideoID: request.videoID, in: request.stagingDirectory)
        return ["--postprocessor-args", "ExtractAudio+ffmpeg:-progress \"" + path(of: progressFile) + "\""]
    }

    /// A file URL's on-disk path, percent-decoded — the engine wants a path, not a URL.
    static func path(of url: URL) -> String {
        url.path(percentEncoded: false)
    }
}
