// FakeDownloadToolProvider — a deterministic, disk-free ``DownloadToolProviding`` double.
//
// Answers with configured tool locations and a configured version, and lets a test
// script the update lifecycle (up-to-date / update available / update fails) without
// touching Application Support, the app bundle, or the network. Call counts are
// recorded so a consumer test can assert `prepare()` is idempotent and that an update
// is only applied when one was actually offered.
//
// Style mirrors `FakeStemSeparator`: a `@unchecked Sendable` final class guarded by an
// `NSLock` (the protocol is `Sendable`, not `@MainActor`).
import Foundation
import Services

/// A canned ``DownloadToolProviding`` for hermetic tests and previews.
public final class FakeDownloadToolProvider: DownloadToolProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var configuredYtDlpURL: URL
    private var configuredFFmpegDirectoryURL: URL
    private var configuredVersion: String
    private var configuredUpdate: ToolUpdateAvailability
    private var configuredPrepareError: (any Error)?
    private var configuredUpdateError: (any Error)?
    private var prepareCalls = 0
    private var versionCalls = 0
    private var checkForUpdateCalls = 0
    private var applyUpdateCalls = 0

    /// - Parameters:
    ///   - ytDlpURL: What ``ytDlpURL`` reports. A path only — nothing is created.
    ///   - ffmpegDirectoryURL: What ``ffmpegDirectoryURL`` reports.
    ///   - version: What ``version()`` reports, and the installed side of an update check.
    ///   - update: What ``checkForUpdate()`` reports. Defaults to up-to-date at `version`.
    ///   - prepareError: When set, ``prepare()`` and the URL accessors throw it —
    ///     the "tools could not be provisioned" path.
    ///   - updateError: When set, ``applyUpdate()`` throws it instead of succeeding.
    public init(
        ytDlpURL: URL = URL(fileURLWithPath: "/tmp/macamp-fake-tools/yt-dlp"),
        ffmpegDirectoryURL: URL = URL(fileURLWithPath: "/tmp/macamp-fake-tools"),
        version: String = "2025.01.01",
        update: ToolUpdateAvailability? = nil,
        prepareError: (any Error)? = nil,
        updateError: (any Error)? = nil
    ) {
        configuredYtDlpURL = ytDlpURL
        configuredFFmpegDirectoryURL = ffmpegDirectoryURL
        configuredVersion = version
        configuredUpdate = update ?? .upToDate(version: version)
        configuredPrepareError = prepareError
        configuredUpdateError = updateError
    }

    // MARK: - DownloadToolProviding

    public var ytDlpURL: URL {
        get async throws {
            try lock.withLock {
                if let error = configuredPrepareError { throw error }
                return configuredYtDlpURL
            }
        }
    }

    public var ffmpegDirectoryURL: URL {
        get async throws {
            try lock.withLock {
                if let error = configuredPrepareError { throw error }
                return configuredFFmpegDirectoryURL
            }
        }
    }

    public func version() async throws -> String {
        try lock.withLock {
            versionCalls += 1
            if let error = configuredPrepareError { throw error }
            return configuredVersion
        }
    }

    public func prepare() async throws {
        try lock.withLock {
            prepareCalls += 1
            if let error = configuredPrepareError { throw error }
        }
    }

    public func checkForUpdate() async throws -> ToolUpdateAvailability {
        try lock.withLock {
            checkForUpdateCalls += 1
            if let error = configuredUpdateError { throw error }
            return configuredUpdate
        }
    }

    /// Installs the latest version reported by ``checkForUpdate()`` and reports it as
    /// current afterwards, so a second check sees the post-update state.
    public func applyUpdate() async throws -> String {
        try lock.withLock {
            applyUpdateCalls += 1
            if let error = configuredUpdateError { throw error }
            if case let .updateAvailable(_, latest) = configuredUpdate {
                configuredVersion = latest
                configuredUpdate = .upToDate(version: latest)
            }
            return configuredVersion
        }
    }

    // MARK: - Test helpers

    public var prepareCallCount: Int {
        lock.withLock { prepareCalls }
    }

    public var versionCallCount: Int {
        lock.withLock { versionCalls }
    }

    public var checkForUpdateCallCount: Int {
        lock.withLock { checkForUpdateCalls }
    }

    public var applyUpdateCallCount: Int {
        lock.withLock { applyUpdateCalls }
    }

    /// Repoints what ``checkForUpdate()`` reports, mid-test.
    public func setUpdate(_ update: ToolUpdateAvailability) {
        lock.withLock { configuredUpdate = update }
    }

    /// Arms or clears the provisioning failure used by ``prepare()`` and the URL accessors.
    public func setPrepareError(_ error: (any Error)?) {
        lock.withLock { configuredPrepareError = error }
    }
}
