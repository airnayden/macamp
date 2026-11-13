// ProfileAvatarImage — cross-platform (AppKit/UIKit-free) helpers for a profile's
// custom avatar image.
//
// `write` downsamples an arbitrary picked image to a small square-ish PNG the app
// stores in Application Support; `load` decodes that stored PNG back to a
// `CGImage` for ``ProfileAvatarView``. Both go through ImageIO / CoreGraphics only,
// so this compiles verbatim into the macOS, iOS and Widget shells (the PlayerCore
// portability invariant — see scripts/check-playercore-portability.sh).
//
// Convention (load-bearing): `ProfileRecord.avatarImagePath == nil` renders the
// `avatarId` preset; a non-nil absolute path renders the custom image written here.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A typed failure for a custom-avatar image write.
public enum ProfileAvatarImageError: Error, Sendable, Equatable {
    /// `CGImageSourceCreateWithURL` could not read the source image.
    case sourceUnreadable
    /// `CGImageSourceCreateThumbnailAtIndex` returned nil.
    case thumbnailFailed
    /// `CGImageDestinationCreateWithURL` returned nil.
    case destinationUnavailable
    /// `CGImageDestinationFinalize` returned false.
    case encodeFailed
}

/// Stateless read/write helpers for a profile's custom avatar image.
public enum ProfileAvatarImage {
    /// Downsamples `source` so its longest edge is at most `maxPixel` px and writes
    /// it as PNG to `destination` (overwriting any existing file there).
    ///
    /// Uses ImageIO thumbnailing, so the full-resolution source is never decoded
    /// into memory — a 4000 px photo becomes a 256 px avatar without the full
    /// bitmap.
    ///
    /// - Throws: ``ProfileAvatarImageError`` on any read, thumbnail or encode
    ///   failure.
    public static func write(source: URL, to destination: URL, maxPixel: Int = 256) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ProfileAvatarImageError.sourceUnreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        else {
            throw ProfileAvatarImageError.thumbnailFailed
        }
        guard
            let destinationRef = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw ProfileAvatarImageError.destinationUnavailable
        }
        CGImageDestinationAddImage(destinationRef, thumbnail, nil)
        guard CGImageDestinationFinalize(destinationRef) else {
            throw ProfileAvatarImageError.encodeFailed
        }
    }

    /// Loads a `CGImage` from an absolute file path, or `nil` if the file is
    /// missing, unreadable or not a decodable image.
    ///
    /// Never throws and never crashes: a deleted or corrupt custom avatar degrades
    /// gracefully to the preset fallback in ``ProfileAvatarView``.
    public static func load(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
