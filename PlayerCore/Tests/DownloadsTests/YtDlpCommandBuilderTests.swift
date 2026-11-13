// Golden-array coverage for `YtDlpCommandBuilder`.
//
// Every literal the builder can emit is spelled out HERE, independently of the
// production source — including a second, test-local copy of the per-format quality
// table. That double entry is the point: a test that read `YtDlpArgumentTables` back
// would agree with any value the table happened to hold, including a wrong one.
//
// One array (`m4a`/`best`) is written out whole, with no composition at all, so the
// shape itself is pinned; the remaining eleven cells are composed from the same
// test-local fragments so a per-cell difference is legible in the failure message.
import Foundation
import Services
import Testing

/// One format × quality cell of the quality table, with its EXPECTED argument fragment
/// written out independently of the production table.
struct QualityCell: CustomStringConvertible {
    let format: DownloadAudioFormat
    let quality: DownloadAudioQuality
    /// The `--audio-quality` fragment, or `[]` when the format takes no quality argument.
    let fragment: [String]

    var description: String {
        "\(format.rawValue)/\(quality.rawValue)"
    }
}

@Suite("yt-dlp command builder")
struct YtDlpCommandBuilderTests {
    static let videoID = "dQw4w9WgXcQ"
    static let downloadsDirectory = URL(fileURLWithPath: "/Users/test/Music/MacAMP Downloads")
    static let stagingDirectory = URL(fileURLWithPath: "/Users/test/Library/Caches/MacAMP/Downloads")
    static let toolsDirectory = URL(fileURLWithPath: "/Users/test/Library/Application Support/MacAMP/Tools")

    // MARK: - Test-local golden fragments

    static let expectedHead: [String] = [
        "--ignore-config",
        "--no-config-locations",
        "--no-color",
        "--newline",
        "--progress",
        "--no-playlist",
        "--progress-template",
        "download:MACAMP-P|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.eta)s|%(progress.speed)s",
        "--progress-template",
        "postprocess:MACAMP-PP|%(progress.status)s|%(progress.postprocessor)s",
        "--print",
        "after_move:MACAMP-FILE|%(filepath)s",
    ]

    static let expectedTail: [String] = [
        "--embed-thumbnail",
        "--embed-metadata",
        "-P",
        "home:/Users/test/Music/MacAMP Downloads",
        "-P",
        "temp:/Users/test/Library/Caches/MacAMP/Downloads",
        "-o",
        "%(title)s [%(id)s].%(ext)s",
        "--ffmpeg-location",
        "/Users/test/Library/Application Support/MacAMP/Tools",
        "--cache-dir",
        "/Users/test/Library/Application Support/MacAMP/Tools/yt-dlp-cache",
        "--postprocessor-args",
        // The QUOTES are restated here as literal characters because they are the whole
        // point of the argument. yt-dlp `shlex.split`s this value, and both the real
        // staging directory and this filename contain a space — unquoted, ffmpeg reads
        // the fragments as output files and EVERY download fails (measured, todo 8).
        "ExtractAudio+ffmpeg:-progress \"/Users/test/Library/Caches/MacAMP/Downloads/ffprogress [dQw4w9WgXcQ].txt\"",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    ]

    /// The whole quality table, restated by hand. mp3 uses libmp3lame's VBR scale;
    /// m4a and opus use bitrate strings; flac emits no quality argument at all.
    static let cells: [QualityCell] = [
        QualityCell(format: .m4a, quality: .best, fragment: ["--audio-quality", "256K"]),
        QualityCell(format: .m4a, quality: .high, fragment: ["--audio-quality", "192K"]),
        QualityCell(format: .m4a, quality: .medium, fragment: ["--audio-quality", "128K"]),
        QualityCell(format: .mp3, quality: .best, fragment: ["--audio-quality", "0"]),
        QualityCell(format: .mp3, quality: .high, fragment: ["--audio-quality", "5"]),
        QualityCell(format: .mp3, quality: .medium, fragment: ["--audio-quality", "7"]),
        QualityCell(format: .opus, quality: .best, fragment: ["--audio-quality", "192K"]),
        QualityCell(format: .opus, quality: .high, fragment: ["--audio-quality", "128K"]),
        QualityCell(format: .opus, quality: .medium, fragment: ["--audio-quality", "96K"]),
        QualityCell(format: .flac, quality: .best, fragment: []),
        QualityCell(format: .flac, quality: .high, fragment: []),
        QualityCell(format: .flac, quality: .medium, fragment: []),
    ]

    static func request(_ format: DownloadAudioFormat, _ quality: DownloadAudioQuality) -> YtDlpDownloadRequest {
        YtDlpDownloadRequest(
            videoID: videoID,
            format: .audio(format, quality),
            downloadsDirectory: downloadsDirectory,
            stagingDirectory: stagingDirectory,
            toolsDirectory: toolsDirectory
        )
    }

    static func arguments(for cell: QualityCell) throws -> [String] {
        try #require(YtDlpCommandBuilder.downloadArguments(for: request(cell.format, cell.quality)))
    }

    // MARK: - The whole array, uncomposed

    /// The plan's happy QA scenario: the default cell's vector, written out with no
    /// composition, so the ORDER of every flag is pinned and not merely its membership.
    @Test("m4a/best matches its golden array byte for byte")
    func m4aBestGoldenArray() throws {
        let arguments = try Self.arguments(for: QualityCell(format: .m4a, quality: .best, fragment: []))
        #expect(arguments == [
            "--ignore-config",
            "--no-config-locations",
            "--no-color",
            "--newline",
            "--progress",
            "--no-playlist",
            "--progress-template",
            "download:MACAMP-P|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.eta)s|%(progress.speed)s",
            "--progress-template",
            "postprocess:MACAMP-PP|%(progress.status)s|%(progress.postprocessor)s",
            "--print",
            "after_move:MACAMP-FILE|%(filepath)s",
            "-x",
            "--audio-format",
            "m4a",
            "--audio-quality",
            "256K",
            "--embed-thumbnail",
            "--embed-metadata",
            "-P",
            "home:/Users/test/Music/MacAMP Downloads",
            "-P",
            "temp:/Users/test/Library/Caches/MacAMP/Downloads",
            "-o",
            "%(title)s [%(id)s].%(ext)s",
            "--ffmpeg-location",
            "/Users/test/Library/Application Support/MacAMP/Tools",
            "--cache-dir",
            "/Users/test/Library/Application Support/MacAMP/Tools/yt-dlp-cache",
            "--postprocessor-args",
            "ExtractAudio+ffmpeg:-progress \"/Users/test/Library/Caches/MacAMP/Downloads/ffprogress [dQw4w9WgXcQ].txt\"",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        ])
    }

    // MARK: - Every cell

    @Test("every format × quality cell matches its golden array", arguments: cells)
    func everyCellMatchesItsGoldenArray(cell: QualityCell) throws {
        let expected = Self.expectedHead
            + ["-x", "--audio-format", cell.format.rawValue]
            + cell.fragment
            + Self.expectedTail
        let actual = try Self.arguments(for: cell)
        #expect(actual == expected)
    }

    /// flac is lossless: the flag AND its value are absent, not an empty string. A bare
    /// `--audio-quality` with no value would be an engine-side parse error.
    @Test("flac emits no quality argument at all", arguments: DownloadAudioQuality.allCases)
    func flacHasNoQualityArgument(quality: DownloadAudioQuality) throws {
        let arguments = try Self.arguments(
            for: QualityCell(format: .flac, quality: quality, fragment: [])
        )
        #expect(!arguments.contains("--audio-quality"))
        #expect(arguments.contains("--audio-format"))
    }

    /// A row added later must be a DECISION. Without this, a new format would fall
    /// through the table's `nil` and silently inherit flac's "emit nothing".
    @Test("the quality table has a row for every format", arguments: DownloadAudioFormat.allCases)
    func qualityTableIsExhaustive(format: DownloadAudioFormat) {
        #expect(YtDlpArgumentTables.audioQuality[format] != nil)
    }

    // MARK: - Prefetch

    @Test("the prefetch vector matches its golden array")
    func prefetchGoldenArray() throws {
        let url = try downloadTestURL("https://www.youtube.com/playlist?list=PLabc123")
        #expect(YtDlpCommandBuilder.prefetchArguments(for: url) == [
            "--flat-playlist",
            "-J",
            "--no-warnings",
            "--ignore-config",
            "--no-config-locations",
            "--no-color",
            "https://www.youtube.com/playlist?list=PLabc123",
        ])
    }

    /// Stated as its own claim rather than left implicit in the array above: the prefetch
    /// runs no post-processor at all, so asking one for conversion progress would be a
    /// flag with no reader — and `-J` prints a JSON document this must not disturb.
    @Test("the prefetch vector carries no conversion-progress flag")
    func prefetchCarriesNoConversionProgressFlag() throws {
        let url = try downloadTestURL("https://www.youtube.com/playlist?list=PLabc123")
        let arguments = YtDlpCommandBuilder.prefetchArguments(for: url)

        #expect(!arguments.contains("--postprocessor-args"))
        #expect(!arguments.contains { $0.contains("ffprogress") })
    }

    // MARK: - Conversion progress

    /// The path lands in STAGING (never the destination) and carries the same bracketed
    /// marker the per-item purge matches on, so an interrupted row reclaims it.
    @Test("the conversion progress file is a staging artifact of its own video")
    func theConversionProgressFileIsAStagingArtifact() throws {
        let arguments = try Self.arguments(for: QualityCell(format: .m4a, quality: .best, fragment: []))
        let index = try #require(arguments.firstIndex(of: "--postprocessor-args"))
        let value = arguments[index + 1]

        #expect(value.contains(Self.stagingDirectory.path(percentEncoded: false)))
        #expect(!value.contains(Self.downloadsDirectory.path(percentEncoded: false)))
        #expect(DownloadStagingSweeper.isArtifact(
            YtDlpCommandBuilder.ffProgressFileName(forVideoID: Self.videoID),
            ofVideoID: Self.videoID,
            scope: .allArtifacts
        ))
    }

    /// The measured defect from the todo-8 probe, pinned as an assertion rather than as
    /// a comment: yt-dlp `shlex.split`s this value and the real path contains spaces, so
    /// an unquoted one fails EVERY download with `Error opening output files`.
    @Test("the progress path is quoted, and scoped to ExtractAudio", arguments: cells)
    func theProgressPathIsQuotedAndScoped(cell: QualityCell) throws {
        let arguments = try Self.arguments(for: cell)
        let index = try #require(arguments.firstIndex(of: "--postprocessor-args"))
        let value = arguments[index + 1]

        #expect(value.hasPrefix("ExtractAudio+ffmpeg:-progress \""))
        #expect(value.hasSuffix("\""))
        #expect(value.count(where: { $0 == "\"" }) == 2)
    }

    // MARK: - URL reconstruction

    /// Entry URLs are rebuilt from the bare id, never carried over — which is what
    /// actually strips `&list=`/`&t=`/`&index=`/`&si=` out of a share link.
    @Test("the watch URL is rebuilt from the bare id")
    func watchURLIsRebuiltFromTheID() throws {
        let url = try #require(YtDlpCommandBuilder.watchURL(forVideoID: Self.videoID))
        #expect(url.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test("a malformed id yields no watch URL and no argument vector")
    func malformedIDYieldsNothing() {
        #expect(YtDlpCommandBuilder.watchURL(forVideoID: "too-short") == nil)
        let request = YtDlpDownloadRequest(
            videoID: "too-short",
            format: .default,
            downloadsDirectory: Self.downloadsDirectory,
            stagingDirectory: Self.stagingDirectory,
            toolsDirectory: Self.toolsDirectory
        )
        #expect(YtDlpCommandBuilder.downloadArguments(for: request) == nil)
    }

    /// The queued URL carries the id alone even when the paste dragged playlist context
    /// with it — the builder never sees the original URL, only the canonical id.
    @Test("playlist context never reaches the argument vector")
    func playlistContextIsStripped() throws {
        let pasted = try downloadTestURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc&index=3&t=42")
        let id = try #require(YouTubeURLNormalizer.canonicalVideoID(from: pasted))
        let arguments = try #require(YtDlpCommandBuilder.downloadArguments(for: Self.request(.m4a, .best)))
        #expect(id == Self.videoID)
        #expect(arguments.last == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(!arguments.contains { $0.contains("list=") })
    }

    // MARK: - Cross-cutting invariants

    /// `--print` implies `--quiet`, which suppresses the progress reporter; only
    /// `--progress` forces it back on. Without it the sentinel lines never appear.
    @Test("--progress and --embed-thumbnail are unconditional", arguments: cells)
    func mandatoryFlagsArePresent(cell: QualityCell) throws {
        let arguments = try Self.arguments(for: cell)
        #expect(arguments.contains("--progress"))
        #expect(arguments.contains("--embed-thumbnail"))
        #expect(arguments.contains("--ignore-config"))
        #expect(arguments.contains("--no-config-locations"))
    }

    /// A download must never mutate the tool running it.
    @Test("no vector ever carries a self-update flag")
    func noSelfUpdateFlag() throws {
        let playlist = try downloadTestURL("https://www.youtube.com/playlist?list=PLabc123")
        var vectors = [YtDlpCommandBuilder.prefetchArguments(for: playlist)]
        for cell in Self.cells {
            let vector = try Self.arguments(for: cell)
            vectors.append(vector)
        }
        let forbidden = ["-U", "--update", "--update-to"]
        for vector in vectors {
            #expect(!vector.contains { forbidden.contains($0) })
        }
    }
}
