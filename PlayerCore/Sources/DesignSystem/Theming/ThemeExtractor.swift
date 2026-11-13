import CryptoKit
import Foundation

/// Derives an ``AlbumTheme`` (dominant accent + complementary background) from
/// album-art image data.
///
/// ## Off the main thread
/// `ThemeExtractor` is an `actor`, so every call runs on the cooperative
/// executor — never the main thread. The expensive pixel work (downsample +
/// histogram) therefore cannot block UI. Cross-platform by mandate: decoding goes
/// through `CGImageSource` (ImageIO), never `NSImage`/`UIImage`.
///
/// ## Caching
/// Extraction is memoized by the SHA-256 of the image bytes. A second request for
/// the same artwork is served from the cache without re-reading any pixels — only
/// the (cheap) accessibility-dependent assembly re-runs, so changing
/// ``ThemePresentationOptions`` never forces a re-extraction.
///
/// ## Accessibility
/// The app shell injects ``ThemePresentationOptions`` (it reads the platform
/// settings PlayerCore cannot). Reduce-transparency collapses the gradient to a
/// flat solid; increase-contrast boosts the accent and its foreground.
public actor ThemeExtractor {
    private var paletteCache: [String: ExtractedPalette] = [:]

    /// Number of *pixel extractions* performed. Cache hits do not increment it —
    /// the invariant the tests assert.
    public private(set) var extractionCount = 0

    /// Whether the most recent extraction ran on the main thread. Always `false`
    /// in practice (the actor runs off-main); exposed so tests can prove it.
    public private(set) var lastExtractionOnMainThread = false

    private let maxSampleDimension: Int

    /// - Parameter maxSampleDimension: Longest edge the artwork is downsampled to
    ///   before histogramming. 48 px is ample for a stable dominant color and
    ///   keeps the work in the sub-millisecond range.
    public init(maxSampleDimension: Int = 48) {
        self.maxSampleDimension = max(8, maxSampleDimension)
    }

    /// Returns the theme for the given image data, extracting (and caching) the
    /// palette on a miss or reusing the cached palette on a hit.
    public func theme(
        from data: Data,
        options: ThemePresentationOptions = .default
    ) -> AlbumTheme {
        let hash = Self.contentHash(of: data)
        let palette: ExtractedPalette
        if let cached = paletteCache[hash] {
            palette = cached
        } else {
            lastExtractionOnMainThread = Thread.isMainThread
            palette = Self.extractPalette(from: data, maxDimension: maxSampleDimension)
                ?? .neutralFallback
            paletteCache[hash] = palette
            extractionCount += 1
        }
        return Self.assembleTheme(palette: palette, options: options, contentHash: hash)
    }

    /// Whether a palette for the given image data is already cached.
    public func isCached(_ data: Data) -> Bool {
        paletteCache[Self.contentHash(of: data)] != nil
    }

    /// Drops all memoized palettes.
    public func clearCache() {
        paletteCache.removeAll()
    }

    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
