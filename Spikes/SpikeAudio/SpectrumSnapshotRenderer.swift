import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Headless offscreen renderer: rasterizes one spectrum frame to a PNG using the same
/// Metal shader as the live view. Lets the macOS evidence frames be captured
/// deterministically in-process, with no window server or screenshot tooling.
final class SpectrumSnapshotRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let bandBuffer: MTLBuffer

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? makeSpectrumLibrary(device),
              let vertex = library.makeFunction(name: "spectrum_vertex"),
              let fragment = library.makeFunction(name: "spectrum_fragment")
        else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let bandBuffer = device.makeBuffer(
                  length: MemoryLayout<Float>.stride * SpectrumFFT.bandCount,
                  options: .storageModeShared)
        else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.bandBuffer = bandBuffer
    }

    func renderPNG(bands: [Float], width: Int, height: Int, to url: URL) -> Bool {
        bands.withUnsafeBytes { source in
            bandBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            return false
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(bandBuffer, offset: 0, index: 0)
        var count = UInt32(SpectrumFFT.bandCount)
        encoder.setFragmentBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * height)
        raw.withUnsafeMutableBytes { destination in
            texture.getBytes(destination.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(raw) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
