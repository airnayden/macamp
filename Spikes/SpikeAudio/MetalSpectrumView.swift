import MetalKit
import SwiftUI

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Cross-platform SwiftUI wrapper around an `MTKView` that draws the live spectrum.
///
/// PULL-DON'T-PUSH: the `MTKView` draw loop pulls the freshest window of samples
/// from the SPSC ring buffer, runs the FFT, and renders — there is no per-frame
/// `main.async` from the audio thread.
struct MetalSpectrumView: PlatformViewRepresentable {
    let ringBuffer: SPSCRingBuffer

    func makeCoordinator() -> Coordinator { Coordinator(ringBuffer: ringBuffer) }

    #if os(macOS)
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateNSView(_ nsView: MTKView, context: Context) {}
    #else
    func makeUIView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateUIView(_ uiView: MTKView, context: Context) {}
    #endif

    final class Coordinator: NSObject, MTKViewDelegate {
        private let ringBuffer: SPSCRingBuffer
        private let fft = SpectrumFFT()
        private let device: MTLDevice
        private let queue: MTLCommandQueue
        private var pipeline: MTLRenderPipelineState!
        private let scratch: UnsafeMutablePointer<Float>
        private let bandBuffer: MTLBuffer

        init(ringBuffer: SPSCRingBuffer) {
            self.ringBuffer = ringBuffer
            self.device = MTLCreateSystemDefaultDevice()!
            self.queue = device.makeCommandQueue()!
            self.scratch = .allocate(capacity: SpectrumFFT.fftSize)
            self.scratch.initialize(repeating: 0, count: SpectrumFFT.fftSize)
            self.bandBuffer = device.makeBuffer(
                length: MemoryLayout<Float>.stride * SpectrumFFT.bandCount,
                options: .storageModeShared
            )!
            super.init()
            buildPipeline()
        }

        deinit { scratch.deallocate() }

        func makeView() -> MTKView {
            let view = MTKView(frame: .zero, device: device)
            view.delegate = self
            view.preferredFramesPerSecond = 60
            view.colorPixelFormat = .bgra8Unorm
            view.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1)
            view.isPaused = false
            view.enableSetNeedsDisplay = false
            return view
        }

        private func buildPipeline() {
            let library = try! makeSpectrumLibrary(device)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "spectrum_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "spectrum_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // Pull the latest window, compute the spectrum, upload, draw.
            ringBuffer.readLatest(into: scratch, count: SpectrumFFT.fftSize)
            let bands = fft.process(scratch)
            bands.withUnsafeBytes { source in
                bandBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
            }

            guard let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            else { return }

            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBuffer(bandBuffer, offset: 0, index: 0)
            var count = UInt32(SpectrumFFT.bandCount)
            encoder.setFragmentBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
