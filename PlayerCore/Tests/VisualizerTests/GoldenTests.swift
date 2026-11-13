import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import Visualizer

@Suite("Visualizer golden render")
struct GoldenTests {
    private enum GoldenError: Error {
        case cgImage
        case bitmapContext
        case destination
        case finalize
    }

    private static let side = 128
    private static let bytesPerRow = side * 4

    @Test("seeded bars render matches the golden fixture")
    func barsGoldenMatches() throws {
        // No GPU (headless CI) -> skip; an early return is a passing test.
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let renderer = try #require(MetalRenderer(device: device, pixelFormat: .rgba8Unorm))
        let raw = try #require(renderer.renderOffline(
            Self.makeBarsFrame(),
            mode: .bars,
            width: Self.side,
            height: Self.side
        ))
        #expect(raw.count == Self.side * Self.side * 4)

        let fixture = Self.fixtureURL(named: "bars-seed42.png")
        if !FileManager.default.fileExists(atPath: fixture.path) {
            try Self.writePNG(raw, to: fixture)
        }

        // Normalise BOTH sides through the same draw path so orientation /
        // colour-space handling is identical and only GPU rasterisation differs.
        let fresh = try #require(Self.normalize(Self.makeImage(from: raw)))
        let reference = try #require(Self.normalize(Self.loadImage(fixture)))
        #expect(Self.meanAbsoluteDifference(fresh, reference) < 6.0)
    }

    // MARK: Frame fixture

    private static func makeBarsFrame() -> VisualizerFrameState {
        var spectrum = [Float](repeating: 0, count: 128)
        var generator = SeededGenerator(seed: 42)
        for index in 0 ..< spectrum.count {
            spectrum[index] = Float.random(in: 0 ... 1, using: &generator)
        }
        let inputs = FrameInputs(spectrum: spectrum, waveform: [], time: 0, seed: 42, motionEnabled: false)
        return VisualizerFrameState.make(
            mode: .bars,
            inputs: inputs,
            config: VisualizerConfig(),
            accent: SIMD4<Float>(0.1, 0.9, 1.0, 1.0),
            background: SIMD4<Float>(0, 0, 0, 1)
        )
    }

    private static func fixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    // MARK: Image helpers

    private static func makeImage(from pixels: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func normalize(_ image: CGImage?) -> [UInt8]? {
        guard let image else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let didDraw: Bool = pixels.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return didDraw ? pixels : nil
    }

    private static func writePNG(_ pixels: [UInt8], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let image = makeImage(from: pixels) else { throw GoldenError.cgImage }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw GoldenError.destination }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GoldenError.finalize }
    }

    private static func meanAbsoluteDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .greatestFiniteMagnitude }
        var total = 0.0
        for index in 0 ..< lhs.count {
            total += abs(Double(lhs[index]) - Double(rhs[index]))
        }
        return total / Double(lhs.count)
    }
}
