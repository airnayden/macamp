// ProfileAvatarImageStore — copies a picked avatar image into the app's
// Application Support container as a downsampled PNG, and removes it on cleanup.
//
// The editor persists the RETURNED absolute path on `ProfileRecord.avatarImagePath`;
// the original picked file is never referenced again (it may move or be deleted,
// and its security scope is transient — so we always COPY, never link). All image
// work goes through DesignSystem's AppKit-free ``ProfileAvatarImage``.
import DesignSystem
import Foundation

/// Persists custom profile avatar images under Application Support and removes them.
struct ProfileAvatarImageStore {
    /// Subdirectory (under Application Support) that holds copied avatar PNGs.
    private static let directoryName = "MacAMP/ProfileAvatars"

    /// Downsamples and copies `sourceURL` into Application Support, returning the
    /// absolute path of the stored PNG (to persist on `ProfileRecord.avatarImagePath`).
    ///
    /// - Throws: a file-system error if the directory can't be created, or a
    ///   ``ProfileAvatarImageError`` if the source can't be read/encoded.
    func importImage(from sourceURL: URL) throws -> String {
        let directory = try Self.avatarsDirectory()
        let destination = directory.appendingPathComponent("\(UUID().uuidString).png")
        try ProfileAvatarImage.write(source: sourceURL, to: destination)
        return destination.path
    }

    /// Best-effort delete of a stored avatar image. Never throws — a missing file
    /// is a silent no-op.
    func remove(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The `Application Support/MacAMP/ProfileAvatars` directory, created if absent.
    private static func avatarsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
