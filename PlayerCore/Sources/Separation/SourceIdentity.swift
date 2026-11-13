// SourceIdentity — the plain source-file fingerprint recorded alongside a cached
// instrumental so the cache can enumerate which songs it can serve.
//
// The content-addressed ``SeparationCacheKey`` is a one-way SHA-256 digest: given a
// key you cannot recover the file it belongs to. To let downstream consumers (the
// karaoke-ready store, todo 6) list the songs a warm cache can play back instantly,
// each entry now also records the plain source-file identity that produced it —
// path, size and mtime, the same cheap fingerprint the library scanner uses. This
// is stored on the entry and surfaced (with the entry's key hex) as a ``ReadyRecord``
// through ``InstrumentalCaching/readySnapshot()``. Foundation-only — no AppKit/UIKit
// (PlayerCore portability invariant).
import Foundation

/// The identity of the source file a cached instrumental was rendered from.
///
/// Recorded on a cache entry so the cache can enumerate servable songs by their real
/// file path (the ``SeparationCacheKey`` alone is a one-way digest). Carries the same
/// `(path, size, mtime)` fingerprint the library scanner fingerprints on.
public struct SourceIdentity: Sendable, Equatable {
    /// The source file's path.
    public let path: String
    /// The source file's size in bytes.
    public let fileSize: Int64
    /// The source file's modification time (seconds since 1970).
    public let mtime: Double

    /// Creates a source-file identity from an explicit fingerprint.
    public init(path: String, fileSize: Int64, mtime: Double) {
        self.path = path
        self.fileSize = fileSize
        self.mtime = mtime
    }
}
