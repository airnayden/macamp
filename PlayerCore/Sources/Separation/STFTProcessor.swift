import Accelerate
import Foundation

/// Errors thrown when an STFT configuration is invalid or is used inconsistently
/// between analysis and synthesis. All cases are value-comparable so tests can
/// assert on the exact failure.
public enum STFTError: Error, Equatable {
    /// `fftSize` is below 2 or is not a power of two (vDSP radix-2 requires it).
    case invalidFFTSize(Int)
    /// `hopLength` is below 1.
    case invalidHopLength(Int)
    /// `windowLength` is below 1 or exceeds `fftSize`.
    case invalidWindowLength(Int)
    /// `hopLength` exceeds `windowLength`, which leaves gaps that overlap-add
    /// cannot reconstruct. This is the classic "mismatched hop/window" failure.
    case incompatibleHopAndWindow(hop: Int, window: Int)
    /// `inverse` was handed a spectrogram produced by a different configuration.
    case configurationMismatch
}

/// STFT transform parameters, shaped after the karaoke model manifest
/// (`nFFT` / `hopLength` / `windowLength`). Values are ALWAYS injected — never
/// hardcoded — so the processor tracks whatever the converted model declares.
///
/// Decodable directly from `model-manifest.json` (extra manifest keys such as
/// `sampleRate`, `segmentSamples` and `overlap` are ignored here). Downstream
/// consumers (the Core ML separator and the separation pipeline) share this type.
public struct STFTConfiguration: Sendable, Equatable {
    /// FFT length in samples (`nFFT`). Must be a power of two.
    public let fftSize: Int
    /// Analysis/synthesis hop in samples.
    public let hopLength: Int
    /// Hann window length in samples; `<= fftSize` (centered, zero-padded when shorter).
    public let windowLength: Int

    /// Validates the parameters, throwing a typed ``STFTError`` on any mismatch.
    public init(fftSize: Int, hopLength: Int, windowLength: Int) throws {
        guard fftSize >= 2, (fftSize & (fftSize - 1)) == 0 else {
            throw STFTError.invalidFFTSize(fftSize)
        }
        guard hopLength >= 1 else {
            throw STFTError.invalidHopLength(hopLength)
        }
        guard windowLength >= 1, windowLength <= fftSize else {
            throw STFTError.invalidWindowLength(windowLength)
        }
        guard hopLength <= windowLength else {
            throw STFTError.incompatibleHopAndWindow(hop: hopLength, window: windowLength)
        }
        self.fftSize = fftSize
        self.hopLength = hopLength
        self.windowLength = windowLength
    }
}

extension STFTConfiguration: Decodable {
    private enum CodingKeys: String, CodingKey {
        case fftSize = "nFFT"
        case hopLength
        case windowLength
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fftSize: container.decode(Int.self, forKey: .fftSize),
            hopLength: container.decode(Int.self, forKey: .hopLength),
            windowLength: container.decode(Int.self, forKey: .windowLength)
        )
    }
}

/// A framed complex spectrogram in vDSP packed-real scale (each bin is `2x` the
/// mathematical DFT — a uniform factor that cancels exactly on `inverse` and is
/// irrelevant to magnitude-ratio masking or complex subtraction). Bins are the
/// full non-redundant `fftSize / 2 + 1` layout (bin 0 = DC, last bin = Nyquist),
/// laid out row-major as `frameCount * binCount`. `real`/`imag` are mutable so a
/// separator can attenuate the vocal estimate in place before reconstruction.
public struct ComplexSpectrogram: Sendable {
    public let frameCount: Int
    public let binCount: Int
    public var real: [Float]
    public var imag: [Float]
    public let originalSampleCount: Int
    public let configuration: STFTConfiguration

    public init(
        frameCount: Int,
        binCount: Int,
        real: [Float],
        imag: [Float],
        originalSampleCount: Int,
        configuration: STFTConfiguration
    ) {
        self.frameCount = frameCount
        self.binCount = binCount
        self.real = real
        self.imag = imag
        self.originalSampleCount = originalSampleCount
        self.configuration = configuration
    }
}

/// Reusable per-transform vDSP scratch. Allocated once per `forward`/`inverse`
/// call (offline only — never on the audio thread) and released via ARC.
private final class FFTScratch {
    let windowed: UnsafeMutablePointer<Float>
    let realp: UnsafeMutablePointer<Float>
    let imagp: UnsafeMutablePointer<Float>
    let halfN: Int

    init(fftSize: Int) {
        halfN = fftSize / 2
        windowed = .allocate(capacity: fftSize)
        realp = .allocate(capacity: halfN)
        imagp = .allocate(capacity: halfN)
        windowed.initialize(repeating: 0, count: fftSize)
        realp.initialize(repeating: 0, count: halfN)
        imagp.initialize(repeating: 0, count: halfN)
    }

    deinit {
        windowed.deallocate()
        realp.deallocate()
        imagp.deallocate()
    }
}

/// Offline short-time Fourier transform and its exact inverse, built on vDSP's
/// radix-2 real FFT (mirroring `SpectrumAnalyzer`'s setup conventions, but
/// forward **and** inverse and NOT audio-thread-scoped).
///
/// Reconstruction is phase-coherent and, for an unmodified spectrogram, an
/// identity up to float precision: a periodic Hann window is applied on both
/// analysis and synthesis and the overlap-add is normalized by the summed
/// squared window (see ``OverlapAdd``), which is robust for any `hop <= window`.
public final class STFTProcessor: @unchecked Sendable {
    public let configuration: STFTConfiguration
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]

    public init(configuration: STFTConfiguration) {
        self.configuration = configuration
        fftSize = configuration.fftSize
        log2n = vDSP_Length(log2(Double(configuration.fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("STFTProcessor: failed to create FFT setup")
        }
        fftSetup = setup
        window = HannWindow.make(fftSize: configuration.fftSize, windowLength: configuration.windowLength)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Analysis: window, frame (centered, hop-spaced) and forward-FFT `samples`
    /// into a complex spectrogram carrying the original length for exact trimming.
    public func forward(_ samples: [Float]) -> ComplexSpectrogram {
        let sampleCount = samples.count
        let frames = frameCount(forSampleCount: sampleCount)
        let binCount = fftSize / 2 + 1
        var real = [Float](repeating: 0, count: frames * binCount)
        var imag = [Float](repeating: 0, count: frames * binCount)
        let padded = padForAnalysis(samples, frameCount: frames)
        let scratch = FFTScratch(fftSize: fftSize)
        padded.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for frameIndex in 0 ..< frames {
                let bins = forwardFrame(base + frameIndex * configuration.hopLength, scratch: scratch)
                let destination = frameIndex * binCount
                for bin in 0 ..< binCount {
                    real[destination + bin] = bins.real[bin]
                    imag[destination + bin] = bins.imag[bin]
                }
            }
        }
        return ComplexSpectrogram(
            frameCount: frames,
            binCount: binCount,
            real: real,
            imag: imag,
            originalSampleCount: sampleCount,
            configuration: configuration
        )
    }

    /// Synthesis: inverse-FFT each frame, synthesis-window, overlap-add and trim
    /// back to the original sample count. Throws if `spectrogram` was produced by
    /// a different configuration than this processor's.
    public func inverse(_ spectrogram: ComplexSpectrogram) throws -> [Float] {
        guard spectrogram.configuration == configuration else {
            throw STFTError.configurationMismatch
        }
        let scratch = FFTScratch(fftSize: fftSize)
        var overlap = OverlapAdd(
            configuration: configuration,
            synthesisWindow: window,
            sampleCount: spectrogram.originalSampleCount,
            frameCount: spectrogram.frameCount
        )
        for frameIndex in 0 ..< spectrogram.frameCount {
            let frame = inverseFrame(spectrogram, frameIndex: frameIndex, scratch: scratch)
            overlap.add(frame: frame, frameIndex: frameIndex)
        }
        return overlap.finalize()
    }

    // MARK: Private

    private func forwardFrame(
        _ framePointer: UnsafePointer<Float>,
        scratch: FFTScratch
    ) -> (real: [Float], imag: [Float]) {
        let halfN = scratch.halfN
        vDSP_vmul(framePointer, 1, window, 1, scratch.windowed, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: scratch.realp, imagp: scratch.imagp)
        scratch.windowed.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { interleaved in
            vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(halfN))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        var real = [Float](repeating: 0, count: halfN + 1)
        var imag = [Float](repeating: 0, count: halfN + 1)
        real[0] = scratch.realp[0] // DC (imaginary part is zero)
        real[halfN] = scratch.imagp[0] // Nyquist packed into imagp[0]
        for bin in 1 ..< halfN {
            real[bin] = scratch.realp[bin]
            imag[bin] = scratch.imagp[bin]
        }
        return (real, imag)
    }

    private func inverseFrame(
        _ spectrogram: ComplexSpectrogram,
        frameIndex: Int,
        scratch: FFTScratch
    ) -> [Float] {
        let halfN = scratch.halfN
        let offset = frameIndex * spectrogram.binCount
        scratch.realp[0] = spectrogram.real[offset]
        scratch.imagp[0] = spectrogram.real[offset + halfN] // Nyquist back into imagp[0]
        for bin in 1 ..< halfN {
            scratch.realp[bin] = spectrogram.real[offset + bin]
            scratch.imagp[bin] = spectrogram.imag[offset + bin]
        }
        var split = DSPSplitComplex(realp: scratch.realp, imagp: scratch.imagp)
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
        scratch.windowed.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { interleaved in
            vDSP_ztoc(&split, 1, interleaved, 2, vDSP_Length(halfN))
        }
        var frame = [Float](repeating: 0, count: fftSize)
        var scale = 1.0 / Float(2 * fftSize) // vDSP zrip round-trip scale is 1/(2N).
        vDSP_vsmul(scratch.windowed, 1, &scale, &frame, 1, vDSP_Length(fftSize))
        return frame
    }

    /// Number of hop-spaced frames that fully cover `sampleCount` after centering.
    private func frameCount(forSampleCount sampleCount: Int) -> Int {
        guard sampleCount > 0 else { return 1 }
        let hop = configuration.hopLength
        return (sampleCount + hop - 1) / hop + 1
    }

    /// Center-pads `samples` (half an FFT of leading zeros) into a buffer long
    /// enough for `frames` full frames, so every original sample sits in the
    /// constant-overlap interior.
    private func padForAnalysis(_ samples: [Float], frameCount frames: Int) -> [Float] {
        let padLeft = fftSize / 2
        let paddedLength = (frames - 1) * configuration.hopLength + fftSize
        var padded = [Float](repeating: 0, count: paddedLength)
        if !samples.isEmpty {
            padded.replaceSubrange(padLeft ..< (padLeft + samples.count), with: samples)
        }
        return padded
    }
}
