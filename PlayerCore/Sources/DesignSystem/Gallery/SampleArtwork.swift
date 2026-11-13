import CoreGraphics
import Foundation
import ImageIO

/// Generates synthetic album art for the gallery and previews — a real
/// `CGImage`/PNG so the ``ThemeExtractor`` pipeline can be demonstrated end to
/// end without bundling binary assets. Cross-platform CoreGraphics/ImageIO only.
enum SampleArtwork {
    static func gradient(_ colors: [ColorValue], size: Int = 240) -> CGImage? {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        let cgColors = colors.map {
            CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: $0.opacity)
        } as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil)
        else { return nil }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: size, y: size),
            options: []
        )
        return context.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                buffer as CFMutableData,
                "public.png" as CFString,
                1,
                nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}

// MARK: - Gallery sample content

///
/// Dev-only scaffolding rendered via Text(verbatim:); literals here are not
/// shipping translatable copy.
extension SampleArtwork {
    static let galleryTagline = "Album-art design system"
    static let transportTitle = "Transport"
    static let volumeTitle = "Volume"
    static let libraryTitle = "Library"
    static let statesTitle = "States"
    static let paletteTitle = "Palette"
    static let typeTitle = "Type & text"
    static let elevationTitle = "Elevation"
    static let materialsTitle = "Materials"

    static let heroTitle = "Velvet Static"
    static let heroArtist = "The Parallax"
    static let heroImage = gradient([
        ColorValue(hex: 0x0F4C5C),
        ColorValue(hex: 0xE36414),
        ColorValue(hex: 0xFCBF49),
    ])

    struct Track: Identifiable {
        let id = UUID()
        let title: String
        let artist: String
        let artwork: CGImage?
        let duration: Duration
        let isPlaying: Bool
    }

    static let tracks: [Track] = [
        Track(
            title: "Velvet Static",
            artist: "The Parallax",
            artwork: heroImage,
            duration: .seconds(245),
            isPlaying: true
        ),
        Track(
            title: "Northern Drift",
            artist: "Hollowpine",
            artwork: gradient([ColorValue(hex: 0x1B263B), ColorValue(hex: 0x415A77), ColorValue(hex: 0x778DA9)]),
            duration: .seconds(198),
            isPlaying: false
        ),
        Track(
            title: "Saffron Hours",
            artist: "Mira Solène",
            artwork: gradient([ColorValue(hex: 0x582F0E), ColorValue(hex: 0xBB9457), ColorValue(hex: 0xFFE6A7)]),
            duration: .seconds(263),
            isPlaying: false
        ),
        Track(
            title: "Glass Cathedral",
            artist: "Aerolith",
            artwork: nil,
            duration: .seconds(312),
            isPlaying: false
        ),
    ]
}
