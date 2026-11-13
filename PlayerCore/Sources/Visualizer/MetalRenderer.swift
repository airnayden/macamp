import CoreGraphics
import Foundation
import Metal

// MARK: - VizUniforms

/// Swift mirror of the Metal `VizUniforms` struct in ``MetalShaders``.
///
/// Field order, types, and the resulting 64-byte layout MUST match the MSL
/// definition exactly: `SIMD4<Float>` forces 16-byte alignment, so the compiler
/// inserts 4 bytes of padding after `particleCount` — the same padding MSL
/// applies before `accent`.
struct VizUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var motionEnabled: UInt32
    var barCount: UInt32
    var waveCount: UInt32
    var particleCount: UInt32
    var accent: SIMD4<Float>
    var background: SIMD4<Float>
}

// MARK: - MetalRenderer

/// Stateless-per-frame Metal renderer for the visualizer modes.
///
/// Buffers are allocated ONCE and reused every frame (zero per-frame GPU
/// allocation): the CPU frame state is `memcpy`-ed into the pre-sized buffers
/// before each draw. One pipeline is built per ``VisualizerMode`` against a
/// single `rgba8Unorm` colour format shared by the live and offline paths.
final class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelines: [VisualizerMode: MTLRenderPipelineState]
    private let pixelFormat: MTLPixelFormat
    private let buffers: Buffers

    /// Mirrored into `VizUniforms.motionEnabled`; host syncs it from the power
    /// controller's reduce-motion state.
    var motionEnabled = true

    private static let barsCapacity = 128
    private static let waveformCapacity = 512
    private static let particlesCapacity = 64
    private static let uniformsIndex = 3
    private static let bytesPerPixel = 4

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: MetalShaders.source, options: nil),
              let vertex = library.makeFunction(name: "viz_vertex"),
              let states = Self.makePipelines(
                  device: device,
                  library: library,
                  vertex: vertex,
                  pixelFormat: pixelFormat
              ),
              let allocated = Self.makeBuffers(device: device)
        else { return nil }
        self.device = device
        commandQueue = queue
        pipelines = states
        self.pixelFormat = pixelFormat
        buffers = allocated
    }

    // MARK: Encoding

    /// Copies `frame` into the reusable buffers (zero allocation) and records a
    /// single full-screen-triangle draw for `mode` into `encoder`.
    func encode(
        _ frame: VisualizerFrameState,
        mode: VisualizerMode,
        into encoder: MTLRenderCommandEncoder,
        size: CGSize
    ) {
        guard let pipeline = pipelines[mode] else { return }
        writeUniforms(frame, size: size)
        copyFloats(frame.bars, into: buffers.bars, capacity: Self.barsCapacity)
        copyFloats(frame.waveform, into: buffers.waveform, capacity: Self.waveformCapacity)
        copyParticles(frame.particles, into: buffers.particles, capacity: Self.particlesCapacity)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffers.uniforms, offset: 0, index: Self.uniformsIndex)
        encoder.setFragmentBuffer(buffers.bars, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffers.waveform, offset: 0, index: 1)
        encoder.setFragmentBuffer(buffers.particles, offset: 0, index: 2)
        encoder.setFragmentBuffer(buffers.uniforms, offset: 0, index: Self.uniformsIndex)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Live path: encodes into `descriptor`, presents `drawable`, commits.
    func renderLive(
        _ frame: VisualizerFrameState,
        mode: VisualizerMode,
        descriptor: MTLRenderPassDescriptor,
        drawable: MTLDrawable,
        size: CGSize
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        encode(frame, mode: mode, into: encoder, size: size)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Offline path: renders to an off-screen `rgba8Unorm` texture and returns
    /// the raw RGBA8 bytes (row-major, `width * height * 4`). Used by golden
    /// tests; returns `nil` on any GPU-resource failure.
    func renderOffline(
        _ frame: VisualizerFrameState,
        mode: VisualizerMode,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        guard width > 0, height > 0,
              let texture = makeOfflineTexture(width: width, height: height),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.offlinePass(texture))
        else { return nil }
        encode(frame, mode: mode, into: encoder, size: CGSize(width: width, height: height))
        encoder.endEncoding()
        #if os(macOS)
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: texture)
                blit.endEncoding()
            }
        #endif
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Self.readPixels(texture, width: width, height: height)
    }

    // MARK: Per-frame buffer copies

    private func writeUniforms(_ frame: VisualizerFrameState, size: CGSize) {
        let uniforms = VizUniforms(
            resolution: SIMD2<Float>(Float(size.width), Float(size.height)),
            time: frame.time,
            motionEnabled: motionEnabled ? 1 : 0,
            barCount: UInt32(min(frame.bars.count, Self.barsCapacity)),
            waveCount: UInt32(min(frame.waveform.count, Self.waveformCapacity)),
            particleCount: UInt32(min(frame.particles.count, Self.particlesCapacity)),
            accent: frame.accent,
            background: frame.background
        )
        withUnsafeBytes(of: uniforms) { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffers.uniforms.contents(), base, MemoryLayout<VizUniforms>.size)
        }
    }

    private func copyFloats(_ values: [Float], into buffer: MTLBuffer, capacity: Int) {
        let count = min(values.count, capacity)
        guard count > 0 else { return }
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer.contents(), base, count * MemoryLayout<Float>.stride)
        }
    }

    private func copyParticles(_ particles: [VizParticle], into buffer: MTLBuffer, capacity: Int) {
        let count = min(particles.count, capacity)
        guard count > 0 else { return }
        particles.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer.contents(), base, count * MemoryLayout<VizParticle>.stride)
        }
    }

    private func makeOfflineTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
            descriptor.storageMode = .managed
        #else
            descriptor.storageMode = .shared
        #endif
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: Static setup

    private struct Buffers {
        let uniforms: MTLBuffer
        let bars: MTLBuffer
        let waveform: MTLBuffer
        let particles: MTLBuffer
    }

    private static func makeBuffers(device: MTLDevice) -> Buffers? {
        guard let uniforms = device.makeBuffer(
            length: MemoryLayout<VizUniforms>.stride,
            options: .storageModeShared
        ),
            let bars = device.makeBuffer(
                length: barsCapacity * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let waveform = device.makeBuffer(
                length: waveformCapacity * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let particles = device.makeBuffer(
                length: particlesCapacity * MemoryLayout<VizParticle>.stride,
                options: .storageModeShared
            )
        else { return nil }
        return Buffers(uniforms: uniforms, bars: bars, waveform: waveform, particles: particles)
    }

    private static func makePipelines(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: MTLFunction,
        pixelFormat: MTLPixelFormat
    ) -> [VisualizerMode: MTLRenderPipelineState]? {
        var result = [VisualizerMode: MTLRenderPipelineState]()
        for mode in VisualizerMode.allCases {
            guard let fragment = library.makeFunction(name: fragmentName(for: mode)) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            result[mode] = state
        }
        return result
    }

    private static func fragmentName(for mode: VisualizerMode) -> String {
        switch mode {
        case .bars: "frag_bars"
        case .oscilloscope: "frag_oscilloscope"
        case .particles: "frag_particles"
        case .aurora: "frag_aurora"
        }
    }

    private static func offlinePass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return pass
    }

    private static func readPixels(_ texture: MTLTexture, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let region = MTLRegionMake2D(0, 0, width, height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: width * bytesPerPixel, from: region, mipmapLevel: 0)
        }
        return pixels
    }
}
