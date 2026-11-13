import Foundation

/// Identifies the volume a file path lives on, plus whether that volume is
/// external and currently mounted.
///
/// `isExternal` distinguishes the boot/internal volume from removable or
/// otherwise-external volumes; `isMounted` is `false` when the volume is known
/// (e.g. an `/Volumes/<name>` mount point) but not currently attached. Together
/// they let the reconciler tell a deleted file (``Availability/missing``) apart
/// from a file that is merely offline (``Availability/externalOffline``).
public struct VolumeIdentity: Sendable, Equatable {
    /// The volume's mount-point root (e.g. `/` or `/Volumes/My Drive`).
    public var root: URL
    /// Whether the volume is external (removable or non-internal).
    public var isExternal: Bool
    /// Whether the volume is currently mounted.
    public var isMounted: Bool

    public init(root: URL, isExternal: Bool, isMounted: Bool) {
        self.root = root
        self.isExternal = isExternal
        self.isMounted = isMounted
    }
}

/// A seam over the file-system facts the availability reconciler needs.
///
/// Abstracted behind a protocol so tests inject a deterministic fake instead of
/// touching real files or mounting real volumes. The production conformer is
/// ``SystemFileSystem``.
public protocol FileSystemProbing: Sendable {
    /// Whether a regular file exists at `path`.
    func fileExists(atPath path: String) -> Bool
    /// The roots of all currently mounted volumes.
    func mountedVolumeURLs() -> [URL]
    /// Classifies the volume that `path` lives on — even when that volume is not
    /// currently mounted.
    func volume(forPath path: String) -> VolumeIdentity
}

/// The production ``FileSystemProbing`` backed by `FileManager` and
/// `URLResourceValues`.
///
/// Stores no state (so it is trivially `Sendable`); every call reads
/// `FileManager.default`. Volume classification prefers the live mounted-volume
/// set for attached drives and falls back to the macOS `/Volumes/<name>`
/// convention for a drive that is currently offline (where resource values are
/// unreadable because the path no longer resolves).
public struct SystemFileSystem: FileSystemProbing {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    public func mountedVolumeURLs() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeURLKey],
            options: [.skipHiddenVolumes]
        ) ?? []
    }

    public func volume(forPath path: String) -> VolumeIdentity {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents

        // Prefer the longest mounted volume that is an ancestor of the path.
        var bestRoot: URL?
        var bestCount = -1
        for volumeURL in mountedVolumeURLs() {
            let root = volumeURL.standardizedFileURL
            let rootComponents = root.pathComponents
            guard rootComponents.count <= pathComponents.count else { continue }
            guard Array(pathComponents.prefix(rootComponents.count)) == rootComponents else { continue }
            if rootComponents.count > bestCount {
                bestRoot = root
                bestCount = rootComponents.count
            }
        }

        if let root = bestRoot {
            return VolumeIdentity(root: root, isExternal: Self.isExternalVolume(root), isMounted: true)
        }

        // Not mounted: derive the mount root from the /Volumes/<name> convention
        // so an offline external drive is still recognised as external.
        if pathComponents.count >= 3, pathComponents[1] == "Volumes" {
            let root = URL(fileURLWithPath: "/Volumes/\(pathComponents[2])").standardizedFileURL
            return VolumeIdentity(root: root, isExternal: true, isMounted: false)
        }
        return VolumeIdentity(
            root: URL(fileURLWithPath: "/").standardizedFileURL,
            isExternal: false,
            isMounted: true
        )
    }

    private static func isExternalVolume(_ root: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey]
        guard let values = try? root.resourceValues(forKeys: keys) else {
            return root.path != "/" && root.path.hasPrefix("/Volumes/")
        }
        let isRemovable = values.volumeIsRemovable ?? false
        let isInternal = values.volumeIsInternal ?? true
        return isRemovable || !isInternal
    }
}
