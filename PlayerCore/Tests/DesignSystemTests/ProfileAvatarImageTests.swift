// Verifies the AppKit-free custom-avatar image helpers: `write` produces a PNG
// downsampled to at most `maxPixel` on the long edge, and `load` degrades to nil
// for a missing/undecodable file (never throwing, never crashing).
import CoreGraphics
import DesignSystem
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("ProfileAvatarImageTests")
struct ProfileAvatarImageTests {
    @Test("write downsamples a source image to at most maxPixel on the long edge")
    func writeDownsamples() throws {
        let directory = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.png")
        try Self.writeSquarePNG(to: source, size: 512)

        let destination = directory.appendingPathComponent("thumb.png")
        try ProfileAvatarImage.write(source: source, to: destination, maxPixel: 64)

        #expect(FileManager.default.fileExists(atPath: destination.path))

        let loaded = try #require(ProfileAvatarImage.load(path: destination.path))
        #expect(loaded.width <= 64)
        #expect(loaded.height <= 64)
    }

    @Test("load returns nil for a missing file")
    func loadMissingReturnsNil() {
        #expect(ProfileAvatarImage.load(path: "/nonexistent/path/does-not-exist.png") == nil)
    }
}

// MARK: - Fixtures

private extension ProfileAvatarImageTests {
    enum FixtureError: Error { case context, image, destination, finalize }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileAvatarImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a solid-color square PNG of `size` px via CoreGraphics (no AppKit).
    static func writeSquarePNG(to url: URL, size: Int) throws {
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

        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        guard let image = context.makeImage() else { throw FixtureError.image }
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { throw FixtureError.destination }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalize }
    }
}
