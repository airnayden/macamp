// ArtworkCache — a content-addressed, size-capped disk cache for cover art.
//
// Design goals (all enforced by ArtworkCacheTests):
//   * DEDUPE — blobs are addressed by the SHA-256 of their bytes, so the same
//     cover shared by two albums (a compilation, a re-release) is stored ONCE.
//   * LRU EVICTION — once the on-disk total exceeds the byte cap, the
//     least-recently-used blobs are dropped until it fits again; a blob that was
//     `touch`ed survives over an older untouched one.
//   * WARM-LOAD — an `index.json` sidecar records every blob's hash, size,
//     recency and provenance, so a freshly-constructed cache over the same
//     directory immediately sees previously stored art.
//
// It is an `actor`: all mutation of the index + filesystem is serialised, so the
// resolver can hammer it concurrently from any task. Thumbnailing is delegated to
// ``ArtworkImageProcessing`` (ImageIO), never NSImage/UIImage.
import Foundation

/// A size-capped, content-addressed on-disk artwork cache with LRU eviction.
public actor ArtworkCache {
    /// Per-blob bookkeeping persisted in `index.json`.
    private struct Entry: Codable {
        var hash: String
        var byteSize: Int
        var lastAccess: Int
        var source: String
        var pixelWidth: Int?
        var pixelHeight: Int?
    }

    /// The persisted cache index: blobs keyed by content hash, plus the
    /// album → current-hash mapping.
    private struct Index: Codable {
        var entries: [String: Entry] = [:]
        var albums: [String: String] = [:]
    }

    private let directory: URL
    private let maxByteSize: Int
    private let fileManager: FileManager
    private var index: Index
    /// Monotonic recency clock — bumped on every store/access so LRU ordering is
    /// deterministic and never depends on wall-clock time.
    private var clock: Int

    /// - Parameters:
    ///   - directory: Folder that holds the blob files and `index.json`. Created
    ///     if absent.
    ///   - maxByteSize: Soft cap on the total blob bytes; `0` disables eviction.
    public init(directory: URL, maxByteSize: Int) throws {
        self.directory = directory
        self.maxByteSize = max(0, maxByteSize)
        fileManager = .default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        index = Self.loadIndex(from: Self.indexURL(in: directory), fileManager: .default)
        clock = index.entries.values.map(\.lastAccess).max() ?? 0
    }

    // MARK: Store

    /// Stores a resolved ``ArtworkResult`` for `album`, preserving its provenance
    /// and decoded dimensions.
    @discardableResult
    public func store(_ result: ArtworkResult, for album: ArtworkRequest.AlbumKey) throws -> String {
        try storeBytes(
            result.data,
            source: result.source,
            size: (result.pixelWidth, result.pixelHeight),
            for: album
        )
    }

    /// Stores raw `data` for `album`. Dedupes by content hash, refreshes LRU
    /// recency, evicts if over the cap and persists the index.
    @discardableResult
    public func store(data: Data, source: ArtworkSource, for album: ArtworkRequest.AlbumKey) throws -> String {
        try storeBytes(data, source: source, size: (nil, nil), for: album)
    }

    private func storeBytes(
        _ data: Data,
        source: ArtworkSource,
        size: (width: Int?, height: Int?),
        for album: ArtworkRequest.AlbumKey
    ) throws -> String {
        let hash = ArtworkImageProcessing.contentHash(of: data)
        clock += 1
        if index.entries[hash] == nil {
            let blob = blobURL(for: hash)
            if !fileManager.fileExists(atPath: blob.path) {
                try data.write(to: blob, options: .atomic)
            }
            index.entries[hash] = Entry(
                hash: hash,
                byteSize: data.count,
                lastAccess: clock,
                source: source.rawValue,
                pixelWidth: size.width,
                pixelHeight: size.height
            )
        } else {
            index.entries[hash]?.lastAccess = clock
        }
        index.albums[albumKey(album)] = hash
        try evictIfNeeded()
        try persist()
        return hash
    }

    // MARK: Lookup

    /// The cached art for `album`, or `nil` on a miss. A hit refreshes recency.
    public func cachedArtwork(for album: ArtworkRequest.AlbumKey) -> ArtworkResult? {
        guard
            let hash = index.albums[albumKey(album)],
            let entry = index.entries[hash],
            let data = try? Data(contentsOf: blobURL(for: hash))
        else { return nil }
        clock += 1
        index.entries[hash]?.lastAccess = clock
        try? persist()
        return ArtworkResult(
            data: data,
            contentHash: hash,
            source: .cache,
            pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight
        )
    }

    /// A downsampled PNG of `album`'s cached cover whose longest edge is at most
    /// `maxPixel`, or `nil` if nothing is cached for the album.
    public func thumbnail(for album: ArtworkRequest.AlbumKey, maxPixel: Int) throws -> Data? {
        guard
            let hash = index.albums[albumKey(album)],
            index.entries[hash] != nil,
            let data = try? Data(contentsOf: blobURL(for: hash))
        else { return nil }
        return try ArtworkImageProcessing.downsample(data, maxPixel: maxPixel)
    }

    /// Bumps `hash` to most-recently-used so it survives the next eviction.
    public func touch(hash: String) {
        guard index.entries[hash] != nil else { return }
        clock += 1
        index.entries[hash]?.lastAccess = clock
        try? persist()
    }

    // MARK: Stats (for tests + diagnostics)

    /// The content hash currently mapped to `album`, if any.
    public func cachedHash(for album: ArtworkRequest.AlbumKey) -> String? {
        index.albums[albumKey(album)]
    }

    /// `true` when a blob for `hash` exists in the index AND on disk.
    public func contains(hash: String) -> Bool {
        index.entries[hash] != nil && fileManager.fileExists(atPath: blobURL(for: hash).path)
    }

    /// Number of distinct (deduped) blobs currently stored.
    public func blobCount() -> Int {
        index.entries.count
    }

    /// Sum of all stored blob byte sizes.
    public func currentByteSize() -> Int {
        index.entries.values.reduce(0) { $0 + $1.byteSize }
    }

    // MARK: Eviction + persistence

    private func evictIfNeeded() throws {
        guard maxByteSize > 0 else { return }
        var total = currentByteSize()
        guard total > maxByteSize else { return }
        let ordered = index.entries.values.sorted { $0.lastAccess < $1.lastAccess }
        for entry in ordered {
            guard total > maxByteSize else { break }
            try removeBlob(hash: entry.hash)
            total -= entry.byteSize
        }
    }

    private func removeBlob(hash: String) throws {
        let blob = blobURL(for: hash)
        if fileManager.fileExists(atPath: blob.path) {
            try fileManager.removeItem(at: blob)
        }
        index.entries[hash] = nil
        for (album, linkedHash) in index.albums where linkedHash == hash {
            index.albums[album] = nil
        }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: Self.indexURL(in: directory), options: .atomic)
    }

    private func blobURL(for hash: String) -> URL {
        directory.appendingPathComponent("\(hash).blob")
    }

    private func albumKey(_ key: ArtworkRequest.AlbumKey) -> String {
        "\(key.artist)\u{0}\(key.album)"
    }

    private static func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("index.json")
    }

    private static func loadIndex(from url: URL, fileManager: FileManager) -> Index {
        guard
            fileManager.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Index.self, from: data)
        else { return Index() }
        return decoded
    }
}
