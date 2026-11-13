// SeparationCacheKey — the content-addressed identity of a cached instrumental.
//
// An instrumental is valid only for (a) the EXACT source file it was rendered from
// and (b) the EXACT model version that rendered it. So the key mixes both: a
// SHA-256 over the file identity (canonical path + size + mtime — the same cheap
// fingerprint the library scanner uses to decide re-import, see
// `LibraryScanner`/`FileFingerprint`) XORed with a digest of the model SHA. Change
// the file's bytes (mtime/size), move it (path), OR ship a new model, and the key
// changes — so a stale instrumental is never served. Hashing goes through CryptoKit
// exactly like `ArtworkImageProcessing.contentHash`; this file is AppKit/UIKit-free
// (PlayerCore portability invariant).
import CryptoKit
import Foundation

/// The cache key for a separated instrumental: file identity ⊕ model version.
///
/// Deterministic — the same `(canonicalPath, fileSize, mtime, modelSHA)` always
/// yields the same key, and changing ANY component yields a different key. Backed by
/// a lowercase-hex SHA-256 digest, so it is safe to use directly as an on-disk
/// filename.
public struct SeparationCacheKey: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The lowercase-hex composite digest (64 characters).
    public let hexValue: String

    /// Builds a key from an explicit file identity and model SHA.
    ///
    /// - Parameters:
    ///   - canonicalPath: The file's canonical (symlink-resolved, standardized) path.
    ///   - fileSize: The file's size in bytes.
    ///   - mtime: The file's modification time (seconds since 1970).
    ///   - modelSHA: The separation model's source-package SHA-256 (from its
    ///     manifest). Any string is accepted; it is hashed to a fixed width before
    ///     mixing, so a non-hex or unusually-sized value is still well-defined.
    public init(canonicalPath: String, fileSize: Int64, mtime: Double, modelSHA: String) {
        var fileHasher = SHA256()
        fileHasher.update(data: Data(canonicalPath.utf8))
        fileHasher.update(data: Self.fieldSeparator)
        withUnsafeBytes(of: fileSize.littleEndian) { fileHasher.update(bufferPointer: $0) }
        fileHasher.update(data: Self.fieldSeparator)
        withUnsafeBytes(of: mtime.bitPattern.littleEndian) { fileHasher.update(bufferPointer: $0) }
        let fileDigest = fileHasher.finalize()

        // Normalize the model SHA to a fixed 32-byte digest, then XOR the two digests
        // so the key depends symmetrically on both the file and the model version.
        let modelDigest = SHA256.hash(data: Data(modelSHA.utf8))
        let combined = zip(fileDigest, modelDigest).map { $0 ^ $1 }
        hexValue = combined.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String {
        hexValue
    }

    /// A byte inserted between hashed fields so `("ab", 1)` and `("a", "b1")` cannot
    /// collide (ASCII Unit Separator, never appears in a path).
    private static let fieldSeparator = Data([0x1F])
}

// MARK: - Convenience

public extension SeparationCacheKey {
    /// Reads `url`'s canonical path, size and mtime from disk in a SINGLE stat,
    /// returning the ``SourceIdentity`` fingerprint that both this cache key and the
    /// cache entry's stored source-identity are derived from — so a render stats the
    /// file exactly once and feeds both.
    ///
    /// - Throws: Whatever `FileManager.attributesOfItem(atPath:)` throws when the
    ///   file cannot be stat-ed.
    static func sourceIdentity(for url: URL) throws -> SourceIdentity {
        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return SourceIdentity(path: canonicalPath, fileSize: fileSize, mtime: mtime)
    }

    /// Builds a key from an already-read source-file ``SourceIdentity`` and model SHA.
    /// The identity's `path` is the file's canonical path, so this is equivalent to
    /// ``init(canonicalPath:fileSize:mtime:modelSHA:)`` on the same fingerprint.
    init(identity: SourceIdentity, modelSHA: String) {
        self.init(
            canonicalPath: identity.path,
            fileSize: identity.fileSize,
            mtime: identity.mtime,
            modelSHA: modelSHA
        )
    }

    /// Builds a key by reading `url`'s canonical path, size and mtime from disk.
    ///
    /// - Throws: Whatever `FileManager.attributesOfItem(atPath:)` throws when the
    ///   file cannot be stat-ed.
    init(url: URL, modelSHA: String) throws {
        let identity = try Self.sourceIdentity(for: url)
        self.init(identity: identity, modelSHA: modelSHA)
    }
}
