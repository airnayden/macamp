import Accelerate
import Foundation

/// Computes a 128-band normalized magnitude spectrum from 4096 real samples
/// using a Hann window and an Accelerate (vDSP) radix-2 real FFT.
///
/// All scratch storage is allocated once in `init`; `analyze` performs no heap
/// allocation. Bands are spaced logarithmically across the 2048 FFT bins and
/// normalized to `[0, 1]` from a `[-80, 0]` dB range.
final class SpectrumAnalyzer: @unchecked Sendable {
    /// Real samples one ``analyze(_:into:)`` / ``powerSpectrum(_:into:)`` call consumes.
    static let fftSize = 4096

    /// Magnitude bins the real FFT produces (`fftSize / 2`).
    static let binCount = 2048

    private let fftSize = SpectrumAnalyzer.fftSize
    private let log2n: vDSP_Length = 12
    private let halfN = SpectrumAnalyzer.binCount
    private let bandCount = 128
    private let floorDB: Float = -80

    private let fftSetup: FFTSetup
    private let window: [Float]
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let decibels: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let bandEdges: [Int]

    init() {
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("SpectrumAnalyzer: failed to create FFT setup")
        }
        fftSetup = setup

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = hann

        realp = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        imagp = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        power = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        decibels = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        windowed = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        realp.initialize(repeating: 0, count: halfN)
        imagp.initialize(repeating: 0, count: halfN)
        power.initialize(repeating: 0, count: halfN)
        decibels.initialize(repeating: 0, count: halfN)
        windowed.initialize(repeating: 0, count: fftSize)

        let edgeCount = bandCount
        let halfSize = halfN
        bandEdges = (0 ... edgeCount).map { index in
            max(1, Int(pow(Double(halfSize), Double(index) / Double(edgeCount)).rounded()))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        realp.deallocate()
        imagp.deallocate()
        power.deallocate()
        decibels.deallocate()
        windowed.deallocate()
    }

    /// Analyze `fftSize` real samples into `bandCount` normalized bands.
    func analyze(_ samples: UnsafePointer<Float>, into bands: inout [Float]) {
        transform(samples)
        computeDecibels()
        mapBands(into: &bands)
    }

    /// Runs the same window + real FFT as ``analyze(_:into:)`` but hands back the
    /// raw per-bin power `|X[k]|²` for all `binCount` bins instead of the 128-band
    /// log reduction — no dB conversion, no `[-80, 0]` clamp.
    ///
    /// Spectral-cutoff estimation needs BIN resolution: the topmost log band spans
    /// ~950 Hz at 44.1 kHz, which is wider than the tolerance a cutoff estimate is
    /// judged against. Power (not dB) is what leaves the caller free to average
    /// across windows correctly — averaging decibels would be averaging logarithms.
    func powerSpectrum(_ samples: UnsafePointer<Float>, into destination: UnsafeMutablePointer<Float>) {
        transform(samples)
        destination.update(from: power, count: halfN)
    }

    /// Largest band whose lower edge is `<= bin`, clamped to the last band.
    func bandIndex(forBin bin: Int) -> Int {
        var result = 0
        for band in 0 ..< bandCount where bandEdges[band] <= bin {
            result = band
        }
        return min(result, bandCount - 1)
    }

    // MARK: Private

    private func transform(_ samples: UnsafePointer<Float>) {
        vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { interleaved in
            vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(halfN))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(halfN))
    }

    private func computeDecibels() {
        var reference = Float(halfN * halfN)
        vDSP_vdbcon(power, 1, &reference, decibels, 1, vDSP_Length(halfN), 0)
        var low = floorDB
        var high: Float = 0
        vDSP_vclip(decibels, 1, &low, &high, decibels, 1, vDSP_Length(halfN))
    }

    private func mapBands(into bands: inout [Float]) {
        if bands.count != bandCount {
            bands = [Float](repeating: 0, count: bandCount)
        }
        let range = -floorDB
        for band in 0 ..< bandCount {
            let lowEdge = bandEdges[band]
            let highEdge = max(lowEdge + 1, bandEdges[band + 1])
            var peak = floorDB
            for bin in lowEdge ..< highEdge where bin < halfN {
                peak = max(peak, decibels[bin])
            }
            bands[band] = (peak - floorDB) / range
        }
    }
}
