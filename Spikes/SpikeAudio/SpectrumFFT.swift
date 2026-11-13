import Accelerate

/// Reused vDSP real FFT that turns a window of mono samples into a log-spaced,
/// normalized [0, 1] magnitude spectrum for the Metal bars.
///
/// Size 4096 / Hann window (matching MacAMP's real-time audio research: FFT 4096,
/// hop 1024 ≈ 75% overlap). This runs on the CONSUMER / display thread only — it is
/// NOT real-time-safe (it returns a fresh `[Float]`); it must never run in the tap.
/// The FFT setup, window and scratch buffers are allocated once and reused.
final class SpectrumFFT: @unchecked Sendable {
    static let fftSize = 4096
    static let bandCount = 64

    private let n: Int
    private let log2n: vDSP_Length
    private let halfN: Int
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let bandEdges: [Int]
    private var smoothed: [Float]

    init() {
        let size = SpectrumFFT.fftSize
        n = size
        log2n = vDSP_Length(log2(Double(size)))
        halfN = size / 2
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: size)
        windowed = .allocate(capacity: size)
        realp = .allocate(capacity: size / 2)
        imagp = .allocate(capacity: size / 2)
        power = .allocate(capacity: size / 2)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_NORM))

        // Log-spaced band edges across bins [1, halfN).
        var edges = [Int](repeating: 0, count: SpectrumFFT.bandCount + 1)
        let maxBin = Double(size / 2)
        for i in 0...SpectrumFFT.bandCount {
            let frac = Double(i) / Double(SpectrumFFT.bandCount)
            edges[i] = max(1, Int(pow(maxBin, frac).rounded()))
        }
        bandEdges = edges
        smoothed = [Float](repeating: 0, count: SpectrumFFT.bandCount)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        windowed.deallocate()
        realp.deallocate()
        imagp.deallocate()
        power.deallocate()
    }

    /// `samples` must point to exactly `fftSize` mono Floats. Returns `bandCount`
    /// values in [0, 1] with fast-attack / slow-decay peak smoothing (so a moving
    /// signal yields visibly different frames over time).
    func process(_ samples: UnsafePointer<Float>) -> [Float] {
        vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(n / 2)) // |z|^2 per bin

        let ampScale = 2.0 / Float(n)
        var out = [Float](repeating: 0, count: SpectrumFFT.bandCount)
        for band in 0..<SpectrumFFT.bandCount {
            let lo = min(halfN - 1, bandEdges[band])
            let hi = max(lo + 1, min(halfN, bandEdges[band + 1]))
            var peakPower: Float = 0
            var k = lo
            while k < hi {
                let value = power[k]
                if value > peakPower { peakPower = value }
                k += 1
            }
            let amplitude = sqrtf(peakPower) * ampScale
            let db = 20.0 * log10f(amplitude + 1e-9)
            let normalized = max(0, min(1, (db + 80.0) / 80.0))
            // Fast attack, slow decay (classic spectrum-analyzer peak fall-off).
            let decayed = smoothed[band] * 0.86
            let value = max(normalized, decayed)
            smoothed[band] = value
            out[band] = value
        }
        return out
    }
}
