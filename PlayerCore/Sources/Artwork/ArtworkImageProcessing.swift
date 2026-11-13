// ArtworkImageProcessing — the cross-platform pixel primitives shared by the
// resolver and the disk cache.
//
// Everything here goes through CryptoKit (SHA-256 content addressing) and
// ImageIO / CoreGraphics (decode, downsample, pixel-size read). It deliberately
// NEVER touches `NSImage`/`UIImage`, so it compiles verbatim into the macOS, iOS
// and Widget shells (PlayerCore portability invariant).
//
// The downsampler uses `CGImageSourceCreateThumbnailAtIndex` with
// `kCGImageSourceThumbnailMaxPixelSize`, which decodes a *reduced* image directly
// from the source — the full-resolution bitmap is never materialised in memory.
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Stateless image helpers: content hashing, thumbnail downsampling and a
/// decode-free pixel-size read. All cross-platform (ImageIO / CoreGraphics).
enum ArtworkImageProcessing {
    /// Lowercase-hex SHA-256 of `data`, used as the content-addressed cache key
    /// and for per-album dedupe.
    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads the encoded pixel dimensions WITHOUT decoding the full image.
    ///
    /// Returns `nil` when the bytes are not a decodable image.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// Downsamples `data` so its longest edge is at most `maxPixel`, returning
    /// re-encoded PNG bytes.
    ///
    /// Uses ImageIO thumbnailing so the full-resolution image is never decoded —
    /// list UIs can request a 128 px thumbnail of a 1200 px cover without paying
    /// for the full bitmap.
    static func downsample(_ data: Data, maxPixel: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ArtworkError.decodeFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ArtworkError.decodeFailed
        }
        return try encodePNG(thumbnail)
    }

    /// Encodes a `CGImage` to PNG bytes via ImageIO (`CGImageDestination`).
    static func encodePNG(_ image: CGImage) throws -> Data {
        let buffer = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                buffer as CFMutableData,
                "public.png" as CFString,
                1,
                nil
            )
        else { throw ArtworkError.decodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtworkError.decodeFailed }
        return buffer as Data
    }
}
