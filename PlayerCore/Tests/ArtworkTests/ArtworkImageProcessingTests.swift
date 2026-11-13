@testable import Artwork
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("ArtworkImageProcessingTests")
struct ArtworkImageProcessingTests {
    @Test("downsampling a 1200px cover yields a thumbnail whose longest edge ≤ 128")
    func downsamplesLargeFixtureBelowRequestedSize() throws {
        let original = try Self.fixtureData()
        let originalSize = try #require(ArtworkImageProcessing.pixelSize(of: original))
        #expect(originalSize.width == 1200)
        #expect(originalSize.height == 1200)

        let thumbnail = try ArtworkImageProcessing.downsample(original, maxPixel: 128)
        let thumbnailSize = try #require(ArtworkImageProcessing.pixelSize(of: thumbnail))

        #expect(max(thumbnailSize.width, thumbnailSize.height) <= 128)
        #expect(thumbnailSize.width < 1200)
        #expect(thumbnail.count < original.count)
    }

    @Test("content hash is a stable 64-char lowercase-hex SHA-256")
    func contentHashIsStableHex() {
        let data = Data("the dark side of the moon".utf8)
        let first = ArtworkImageProcessing.contentHash(of: data)
        let second = ArtworkImageProcessing.contentHash(of: data)

        let isAllHexDigits = first.allSatisfy(\.isHexDigit)
        #expect(first == second)
        #expect(first.count == 64)
        #expect(isAllHexDigits)
        #expect(first == first.lowercased())
    }

    @Test("pixel-size read returns nil for non-image bytes")
    func pixelSizeNilForGarbage() {
        #expect(ArtworkImageProcessing.pixelSize(of: Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }
}

// MARK: - Fixture

extension ArtworkImageProcessingTests {
    private enum FixtureError: Error { case context, image, destination, finalize }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/large-cover.png")
    }

    /// Loads the committed 1200×1200 fixture, regenerating it deterministically
    /// if absent (Fixtures is excluded from the target, so it is loaded via
    /// `#filePath`, not `Bundle.module`). Four solid colour quadrants keep the PNG
    /// non-trivial so the thumbnail is unambiguously smaller in bytes.
    static func fixtureData() throws -> Data {
        let url = fixtureURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try generateFixture(at: url)
        }
        return try Data(contentsOf: url)
    }

    private static func generateFixture(at url: URL) throws {
        let size = 1200
        let half = size / 2
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
        else { throw FixtureError.context }

        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 0, width: half, height: half), CGColor(srgbRed: 0.85, green: 0.12, blue: 0.20, alpha: 1)),
            (
                CGRect(x: half, y: 0, width: half, height: half),
                CGColor(srgbRed: 0.10, green: 0.55, blue: 0.85, alpha: 1)
            ),
            (
                CGRect(x: 0, y: half, width: half, height: half),
                CGColor(srgbRed: 0.95, green: 0.80, blue: 0.10, alpha: 1)
            ),
            (
                CGRect(x: half, y: half, width: half, height: half),
                CGColor(srgbRed: 0.15, green: 0.70, blue: 0.30, alpha: 1)
            ),
        ]
        for (rect, color) in quadrants {
            context.setFillColor(color)
            context.fill(rect)
        }

        guard let image = context.makeImage() else { throw FixtureError.image }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw FixtureError.destination }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalize }
    }
}
