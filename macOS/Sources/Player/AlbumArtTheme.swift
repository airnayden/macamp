// AlbumArtTheme — shared album-art theming + small render helpers for the player.
//
// The player chrome recolors around the currently-playing artwork: a dominant
// accent plus an art-derived gradient/material (bounded to accent + background —
// no skin engine). Extraction runs off the main thread in DesignSystem's
// `ThemeExtractor` (an actor) and is cached by content hash, so it never blocks
// the UI and a repeat of the same art is free. `AlbumTheme` is `Sendable`, so it
// crosses the actor boundary cleanly.
//
// This file also holds the cross-platform `CGImage` decode (ImageIO, never
// `NSImage`), a token-shadow helper (DesignSystem's own `shadow(for:)` is
// internal), and the transport time formatter — all reused by `PlayerView` and
// `PlayerBarView`.
import CoreGraphics
import DesignSystem
import Foundation
import ImageIO
import SwiftUI

/// App-side album-art theming utilities.
enum AlbumArtTheming {
    /// One shared extractor so its content-hash palette cache is reused across
    /// the bar and the full player (extraction is sub-millisecond regardless).
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

    /// Off-main variant of ``decode(_:maxPixel:)`` — the thumbnail pass still
    /// fully decodes the source image, so large covers must not decode on the
    /// main actor while chrome is animating (e.g. the now-playing slide-in).
    static func decodeOffMain(_ data: Data?, maxPixel: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            decode(data, maxPixel: maxPixel)
        }.value
    }
}

/// Formats a transport position (seconds) as `m:ss`.
enum PlaybackTime {
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension View {
    /// Applies a ``ShadowToken`` as a black drop shadow (DesignSystem's own
    /// helper is module-internal, so the app target needs its own).
    func shadowToken(_ token: ShadowToken) -> some View {
        shadow(
            color: Color.black.opacity(token.colorOpacity),
            radius: token.radius,
            x: token.offsetX,
            y: token.offsetY
        )
    }
}
