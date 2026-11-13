import CoreGraphics
import DesignSystem
import Foundation
import ImageIO
import Testing

@Suite("ThemeExtractorTests")
struct ThemeExtractorTests {
    /// Crimson band fill — the dominant region the extractor must surface.
    private static let crimson = (red: 200.0 / 255, green: 30.0 / 255, blue: 58.0 / 255)

    @Test("dominant accent is stable within tolerance for a fixture image")
    func stableAccent() async throws {
        let data = try Self.fixtureData()
        let extractor = ThemeExtractor()
        let theme = await extractor.theme(from: data)

        #expect(abs(theme.accent.red - Self.crimson.red) < 0.12)
        #expect(theme.accent.green < 0.35)
        #expect(theme.accent.blue < 0.40)
        #expect(theme.accent.red > theme.accent.green)
        #expect(theme.accent.red > theme.accent.blue)

        let second = await ThemeExtractor().theme(from: data)
        #expect(theme.accent == second.accent)
    }

    @Test("a second call for the same artwork is served from cache")
    func cachesSecondCall() async throws {
        let data = try Self.fixtureData()
        let extractor = ThemeExtractor()

        _ = await extractor.theme(from: data)
        let afterFirst = await extractor.extractionCount
        _ = await extractor.theme(from: data)
        let afterSecond = await extractor.extractionCount
        let cached = await extractor.isCached(data)

        #expect(afterFirst == 1)
        #expect(afterSecond == 1)
        #expect(cached)
    }

    @Test("extraction does not run on the main thread")
    func runsOffMainThread() async throws {
        let data = try Self.fixtureData()
        let extractor = ThemeExtractor()

        _ = await extractor.theme(from: data)
        let onMain = await extractor.lastExtractionOnMainThread

        #expect(onMain == false)
    }

    @Test("reduce-transparency yields a flat solid background, default a gradient")
    func reduceTransparencyCollapsesGradient() async throws {
        let data = try Self.fixtureData()

        let reduced = await ThemeExtractor()
            .theme(from: data, options: ThemePresentationOptions(reduceTransparency: true))
        guard case .solid = reduced.background else {
            Issue.record("expected a solid background under reduce-transparency")
            return
        }

        let standard = await ThemeExtractor().theme(from: data)
        guard case .linearGradient = standard.background else {
            Issue.record("expected a gradient background by default")
            return
        }
    }

    @Test("content hash is a stable 64-char SHA-256 of the bytes")
    func contentHashStable() async throws {
        let data = try Self.fixtureData()
        let extractor = ThemeExtractor()

        let first = await extractor.theme(from: data)
        let second = await extractor.theme(from: data)

        #expect(first.contentHash == second.contentHash)
        #expect(first.contentHash.count == 64)
    }

    @Test("garbage data falls back to a neutral theme without crashing")
    func neutralFallbackForInvalidData() async {
        let extractor = ThemeExtractor()
        let theme = await extractor.theme(from: Data([0x00, 0x01, 0x02, 0x03]))
        #expect(theme.contentHash.count == 64)
    }
}

// MARK: - Fixture

extension ThemeExtractorTests {
    private enum FixtureError: Error { case context, image, destination, finalize }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dominant-crimson.png")
    }

    /// Loads the committed fixture, regenerating it deterministically if absent
    /// (mirrors the Persistence migration-fixture pattern). The image is three
    /// horizontal bands — near-black (25%), crimson (60%), near-white (15%) — so
    /// the saturated crimson must win the histogram while the achromatic extremes
    /// are rejected.
    static func fixtureData() throws -> Data {
        let url = fixtureURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try generateFixture(at: url)
        }
        return try Data(contentsOf: url)
    }

    private static func generateFixture(at url: URL) throws {
        let size = 128
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

        context.setFillColor(CGColor(srgbRed: 18.0 / 255, green: 16.0 / 255, blue: 14.0 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: 32))
        context.setFillColor(CGColor(srgbRed: crimson.red, green: crimson.green, blue: crimson.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 32, width: size, height: 77))
        context.setFillColor(CGColor(srgbRed: 245.0 / 255, green: 244.0 / 255, blue: 240.0 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 109, width: size, height: 19))

        guard let image = context.makeImage() else { throw FixtureError.image }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.png" as CFString,
                1,
                nil
            )
        else { throw FixtureError.destination }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalize }
    }
}
