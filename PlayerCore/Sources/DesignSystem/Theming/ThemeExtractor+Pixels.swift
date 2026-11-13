import CoreGraphics
import Foundation
import ImageIO

/// The raw, accessibility-independent result of histogramming the artwork: a
/// dominant accent, a vibrant secondary (for the gradient) and an overall
/// light/dark verdict. Cached by content hash.
struct ExtractedPalette: Equatable {
    var accent: ColorValue
    var secondary: ColorValue
    var isDark: Bool

    static let neutralFallback = ExtractedPalette(
        accent: ColorValue(hex: 0x8A8782),
        secondary: ColorValue(hex: 0x44413D),
        isDark: true
    )
}

extension ThemeExtractor {
    // MARK: Decode + downsample

    static func extractPalette(from data: Data, maxDimension: Int) -> ExtractedPalette? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return extractPalette(from: image, maxDimension: maxDimension)
    }

    static func extractPalette(from image: CGImage, maxDimension: Int) -> ExtractedPalette? {
        let width = max(1, min(image.width, maxDimension))
        let height = max(1, min(image.height, maxDimension))
        let bytesPerRow = width * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let base = raw.baseAddress,
                let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return histogram(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    // MARK: Histogram

    private struct Accumulator {
        var count = 0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
    }

    private struct Tally {
        var buckets: [Int: Accumulator] = [:]
        var luminanceSum = 0.0
        var samples = 0
    }

    private static let quantBits = 4

    private static func accumulate(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> Tally {
        var tally = Tally()
        let shift = 8 - quantBits
        for row in 0 ..< height {
            let rowOffset = row * bytesPerRow
            for column in 0 ..< width {
                let offset = rowOffset + column * 4
                guard pixels[offset + 3] >= 16 else { continue }
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                let key = ((red >> shift) << (quantBits * 2)) | ((green >> shift) << quantBits) | (blue >> shift)
                var bucket = tally.buckets[key] ?? Accumulator()
                bucket.count += 1
                bucket.red += Double(red) / 255
                bucket.green += Double(green) / 255
                bucket.blue += Double(blue) / 255
                tally.buckets[key] = bucket
                tally.luminanceSum += ColorValue(
                    red: Double(red) / 255,
                    green: Double(green) / 255,
                    blue: Double(blue) / 255
                ).luminance
                tally.samples += 1
            }
        }
        return tally
    }

    private static func histogram(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> ExtractedPalette {
        let tally = accumulate(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
        guard tally.samples > 0 else { return .neutralFallback }
        let isDark = (tally.luminanceSum / Double(tally.samples)) < 0.42

        var bestAccent: (score: Double, color: ColorValue)?
        var bestVibrant: (score: Double, color: ColorValue)?

        for bucket in tally.buckets.values {
            let count = Double(bucket.count)
            let average = ColorValue(
                red: bucket.red / count,
                green: bucket.green / count,
                blue: bucket.blue / count
            )
            let sat = saturation(average)
            let bright = brightness(average)
            let extreme = (bright > 0.96 && sat < 0.08) || bright < 0.06

            if !extreme {
                let score = count * (0.12 + sat) * (1 - abs(bright - 0.6) * 0.55)
                if score > (bestAccent?.score ?? -.infinity) {
                    bestAccent = (score, average)
                }
            }
            let vibrantScore = count * (0.05 + sat * sat)
            if vibrantScore > (bestVibrant?.score ?? -.infinity) {
                bestVibrant = (vibrantScore, average)
            }
        }

        let accent = bestAccent?.color ?? bestVibrant?.color ?? ExtractedPalette.neutralFallback.accent
        let secondary = bestVibrant?.color ?? accent
        return ExtractedPalette(accent: accent, secondary: secondary, isDark: isDark)
    }

    // MARK: Assemble (accessibility-dependent, cheap)

    static func assembleTheme(
        palette: ExtractedPalette,
        options: ThemePresentationOptions,
        contentHash: String
    ) -> AlbumTheme {
        let accent = options.increaseContrast
            ? boostedContrast(palette.accent, isDark: palette.isDark)
            : palette.accent
        let onAccent = foreground(on: accent, increaseContrast: options.increaseContrast)
        let backdrop = deepBackdrop(from: palette.accent, secondary: palette.secondary)

        let background: ThemeBackground = if options.reduceTransparency {
            .solid(backdrop)
        } else {
            .linearGradient(
                stops: [
                    scaled(palette.accent, brightness: 0.42, saturation: 0.78),
                    scaled(palette.secondary, brightness: 0.22, saturation: 0.7),
                    backdrop,
                ],
                angleDegrees: 90
            )
        }

        return AlbumTheme(
            accent: accent,
            onAccent: onAccent,
            background: background,
            isDark: palette.isDark,
            contentHash: contentHash
        )
    }

    // MARK: Color math

    private static func brightness(_ color: ColorValue) -> Double {
        max(color.red, color.green, color.blue)
    }

    private static func saturation(_ color: ColorValue) -> Double {
        let high = max(color.red, color.green, color.blue)
        let low = min(color.red, color.green, color.blue)
        guard high > 0 else { return 0 }
        return (high - low) / high
    }

    private static func scaled(
        _ color: ColorValue,
        brightness target: Double,
        saturation saturationScale: Double
    ) -> ColorValue {
        let high = max(color.red, color.green, color.blue)
        guard high > 0 else {
            return ColorValue(red: target, green: target, blue: target)
        }
        let factor = target / high
        let gray = target
        func channel(_ value: Double) -> Double {
            let scaledValue = value * factor
            return (gray + (scaledValue - gray) * saturationScale).clampedUnit
        }
        return ColorValue(red: channel(color.red), green: channel(color.green), blue: channel(color.blue))
    }

    private static func deepBackdrop(from _: ColorValue, secondary: ColorValue) -> ColorValue {
        scaled(secondary, brightness: 0.12, saturation: 0.6)
    }

    private static func foreground(on accent: ColorValue, increaseContrast: Bool) -> ColorValue {
        let light = ColorValue(hex: increaseContrast ? 0xFFFFFF : 0xF7F4F0)
        let dark = ColorValue(hex: increaseContrast ? 0x000000 : 0x14110E)
        return accent.luminance < 0.5 ? light : dark
    }

    private static func boostedContrast(_ accent: ColorValue, isDark: Bool) -> ColorValue {
        let target = isDark ? 0.66 : 0.5
        return scaled(accent, brightness: max(brightness(accent), target), saturation: 1.0)
    }
}

extension Double {
    var clampedUnit: Double {
        Swift.min(1, Swift.max(0, self))
    }
}
