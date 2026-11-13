// DownloadToolProviding / ToolReleaseFetching — the seams over the download tools
// and over the release feed that updates them.
//
// `DownloadToolProviding` answers "where are yt-dlp and ffmpeg, what version is the
// engine, and can it be updated?". The production conformer copies the seed binaries
// out of the signed .app into Application Support and self-updates yt-dlp there —
// never mutating the bundle. `ToolReleaseFetching` is the network half, split out so
// the tool manager can be tested with zero I/O.
//
// This file imports only Foundation and MUST NOT import AppKit/UIKit, Process, or
// URLSession (PlayerCore portability invariant + the downloader boundary gate). The
// only production `URLSession` lives in one sanctioned macOS shell file.
import Foundation

/// The result of checking the engine's release feed for a newer build.
public enum ToolUpdateAvailability: Sendable, Equatable, Hashable {
    /// The installed engine is current. `version` is what is installed.
    case upToDate(version: String)
    /// A newer engine exists. `installed` is current; `latest` is the published tag.
    case updateAvailable(installed: String, latest: String)

    /// Whether an update can be applied.
    public var hasUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    /// The version installed right now, in either case.
    public var installedVersion: String {
        switch self {
        case let .upToDate(version): version
        case let .updateAvailable(installed, _): installed
        }
    }
}

/// Locates the download tools and owns the engine's version lifecycle.
///
/// `Sendable`, not `@MainActor`: conformers do file I/O from detached tasks. The
/// URL accessors are `async` because resolving them may have to perform the one-time
/// copy-out from the app bundle first.
///
/// Updates cover **yt-dlp only** — ffmpeg rides app releases, because it does not
/// suffer YouTube's breakage cadence. Conformers MUST NOT pass `-U` / `--update-to`
/// to yt-dlp: updating is this protocol's job, not the tool's.
public protocol DownloadToolProviding: Sendable {
    /// The yt-dlp executable to run: the self-updated copy in Application Support when
    /// present, otherwise the seed copied out of the bundle.
    var ytDlpURL: URL { get async throws }

    /// The directory holding `ffmpeg`/`ffprobe`, handed to yt-dlp as `--ffmpeg-location`.
    var ffmpegDirectoryURL: URL { get async throws }

    /// The installed engine version string, for display in settings.
    func version() async throws -> String

    /// Ensures the tools exist and are executable, performing the one-time copy-out
    /// from the app bundle if needed. Idempotent and safe to call on every launch.
    ///
    /// - Throws: ``DownloadError/toolMissing`` when the tools cannot be provisioned.
    func prepare() async throws

    /// Asks the release feed whether a newer engine has been published.
    func checkForUpdate() async throws -> ToolUpdateAvailability

    /// Downloads, checksum-verifies, and atomically installs the latest engine into
    /// Application Support, leaving the signed bundle untouched.
    ///
    /// - Returns: The version string now installed.
    /// - Throws: ``DownloadError/updateFailed(detail:)`` when the update did not
    ///   complete; the previously installed engine stays in place.
    func applyUpdate() async throws -> String
}

/// One published engine release: the tag plus where to get the asset and its checksums.
public struct ToolRelease: Sendable, Equatable, Hashable {
    /// The release tag, used verbatim as the version string.
    public let tag: String
    /// The download URL of the executable asset for this platform.
    public let assetURL: URL
    /// The download URL of the checksum manifest covering ``assetURL``.
    ///
    /// Non-optional on purpose: an unverifiable asset is never installed, so a release
    /// without checksums is not a release this app can consume.
    public let checksumURL: URL

    public init(tag: String, assetURL: URL, checksumURL: URL) {
        self.tag = tag
        self.assetURL = assetURL
        self.checksumURL = checksumURL
    }
}

/// Fetches engine release metadata and bytes.
///
/// The network half of the tool manager, split out so update logic — tag comparison,
/// checksum verification, atomic install, rollback — is testable with a scripted
/// double and zero I/O. `Sendable`, driven from detached tasks.
public protocol ToolReleaseFetching: Sendable {
    /// The most recent published release on the stable channel.
    func fetchLatestRelease() async throws -> ToolRelease

    /// The raw bytes at `url` — an asset or a checksum manifest.
    func fetchData(from url: URL) async throws -> Data
}
