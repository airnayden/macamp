// AppSettingsDownloadTypes — the value type `AppSettings.downloads` is spelled in.
//
// A sibling file for the mechanical reason `AppSettingsTypes.swift` is one:
// `AppSettings.swift` sits at `swiftlint --strict`'s 400-line `file_length` ceiling,
// so a new stored property only fits once its type lives elsewhere.
//
// ONE struct rather than four stored properties, because `@Observable` instruments
// stored properties one at a time: four would be four things a pane has to keep in
// step, and one is a single value a binding writes through.
//
// The struct is a VALUE — it owns no persistence. Storage is six FLAT SCALAR keys
// written by `AppSettings+Downloads.swift`; this type is never encoded as a blob.
import Foundation
import Services

/// The listener's YouTube-download preferences.
public struct DownloadPreferences: Equatable, Sendable {
    /// Where finished downloads are written, as a plain filesystem path, or `nil` to
    /// use the app's default directory. A plain path, not a security-scoped bookmark
    /// (the macOS shell is non-sandboxed), mirroring ``AppSettings/karaokeCacheDirectoryPath``.
    public var destinationPath: String?

    /// The container/codec a finished download is written as.
    public var audioFormat: DownloadAudioFormat

    /// How aggressively the engine chases bitrate.
    public var audioQuality: DownloadAudioQuality

    /// When the downloader tools were last checked for a newer build, or `nil` when
    /// they never have been.
    public var lastEngineUpdateCheck: Date?

    /// Whether a finished download is added to the library on its own.
    ///
    /// **Defaults to `false`**: a download is a file the listener asked for, not a
    /// library decision, and the destination folder is deliberately not a library
    /// root. While this is off the file still lands in ``destinationPath`` — it is
    /// only the import that is withheld, and the Downloads pane says so and names
    /// the folder, because a downloaded track that never appears anywhere is the one
    /// failure this switch can cause.
    public var autoImportEnabled: Bool

    /// How many downloads may transfer at once, always within
    /// `1...DownloadQueueLimits.maxConcurrentDownloads`.
    ///
    /// The range is enforced in
    /// ``init(destinationPath:audioFormat:audioQuality:lastEngineUpdateCheck:autoImportEnabled:maxConcurrent:)``
    /// rather than left to the picker, because the picker is not the only writer: a
    /// hand-edited `defaults` value and a value stored by a build whose ceiling was
    /// different both arrive through the same initializer. The queue clamps again at
    /// every refill (`DownloadQueueService.concurrencyLimit()`) — two clamps because
    /// they answer to different owners, and neither may assume the other ran.
    public var maxConcurrent: Int

    public init(
        destinationPath: String? = nil,
        audioFormat: DownloadAudioFormat = .default,
        audioQuality: DownloadAudioQuality = .default,
        lastEngineUpdateCheck: Date? = nil,
        autoImportEnabled: Bool = false,
        maxConcurrent: Int = DownloadQueueLimits.defaultConcurrentDownloads
    ) {
        self.destinationPath = destinationPath
        self.audioFormat = audioFormat
        self.audioQuality = audioQuality
        self.lastEngineUpdateCheck = lastEngineUpdateCheck
        self.autoImportEnabled = autoImportEnabled
        self.maxConcurrent = DownloadPreferences.clampedConcurrency(maxConcurrent)
    }

    /// `value` brought inside `1...DownloadQueueLimits.maxConcurrentDownloads`.
    public static func clampedConcurrency(_ value: Int) -> Int {
        min(max(value, 1), DownloadQueueLimits.maxConcurrentDownloads)
    }

    /// The concurrency values a listener may choose, ascending — the picker's own
    /// contents, derived from the ceiling so the two can never disagree.
    public static var concurrencyChoices: [Int] {
        Array(1 ... DownloadQueueLimits.maxConcurrentDownloads)
    }
}
