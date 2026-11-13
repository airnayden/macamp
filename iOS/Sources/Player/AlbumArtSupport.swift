// AlbumArtSupport — album-art theming + small render helpers for the iOS player.
//
// Mirrors the macOS target's `AlbumArtTheme` helpers (Task 26): the now-playing
// chrome recolors around the currently-playing artwork via DesignSystem's
// `ThemeExtractor` (an actor, off-main, content-hash cached), and artwork bytes
// are decoded to a cross-platform `CGImage` via ImageIO (never `UIImage`). The
// transport time formatter is shared by the now-playing scrubber.
//
// Everything here is AppKit/UIKit-free (CoreGraphics / ImageIO / SwiftUI /
// DesignSystem), so the player surface stays portable.
import CoreGraphics
import DesignSystem
import Foundation
import ImageIO
import SwiftUI

/// App-side album-art theming utilities.
enum AlbumArtTheming {
    /// One shared extractor so its content-hash palette cache is reused across the
    /// now-playing surfaces (extraction is sub-millisecond regardless).
    static let extractor = ThemeExtractor()

    /// Resolves an ``AlbumTheme`` for encoded artwork bytes, honoring the app's
    /// accessibility presentation flags. Returns `nil` when there is no artwork.
    static func theme(
        forArtwork data: Data?,
        options: ThemePresentationOptions
    ) async -> AlbumTheme? {
        guard let data else { return nil }
        return await extractor.theme(from: data, options: options)
    }
}

/// A `.task(id:)` key that re-resolves the theme when either the artwork or the
/// accessibility presentation changes.
struct AlbumThemeKey: Equatable {
    var contentHash: String?
    var options: ThemePresentationOptions
}

/// Cross-platform album-art decoding for ``ArtworkView`` (which takes `CGImage?`).
enum AlbumArtImage {
    /// Decodes — and downsamples — encoded artwork bytes to a display `CGImage`.
    ///
    /// Uses an ImageIO thumbnail so a full-resolution cover never decodes at full
    /// size on the main actor; `maxPixel` bounds the work. Returns `nil` on
    /// undecodable bytes (the caller then shows the placeholder).
    static func decode(_ data: Data?, maxPixel: Int) -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Formats a transport position (seconds) as `m:ss`.
enum PlaybackTime {
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
