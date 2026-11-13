import Accelerate
import Foundation

/// Builds the periodic Hann window shared by STFT analysis and synthesis.
enum HannWindow {
    /// A periodic Hann window of `windowLength` samples, centered inside an
    /// `fftSize`-length buffer (zero-padded on both sides when shorter). The same
    /// window is used for analysis and synthesis so the summed squared window
    /// (see ``OverlapAdd``) normalizes to a perfect reconstruction.
    static func make(fftSize: Int, windowLength: Int) -> [Float] {
        var full = [Float](repeating: 0, count: fftSize)
        var hann = [Float](repeating: 0, count: windowLength)
        vDSP_hann_window(&hann, vDSP_Length(windowLength), Int32(vDSP_HANN_DENORM))
        let offset = (fftSize - windowLength) / 2
        for index in 0 ..< windowLength {
            full[offset + index] = hann[index]
        }
        return full
    }
}

/// Weighted overlap-add reconstruction of synthesis frames into a single signal.
///
/// Each inverse-FFT frame is multiplied by the synthesis Hann window and summed
/// at its hop position; in parallel the squared window is summed into an envelope.
/// Dividing the accumulator by that envelope yields phase-coherent, gain-correct
/// reconstruction independent of the theoretical COLA constant. The result is
/// trimmed (dropping the centering pad) to EXACTLY the original sample count.
struct OverlapAdd {
    private let hopLength: Int
    private let fftSize: Int
    private let padLeft: Int
    private let sampleCount: Int
    private let synthesisWindow: [Float]
    private var accumulator: [Float]
    private var envelope: [Float]

    init(configuration: STFTConfiguration, synthesisWindow: [Float], sampleCount: Int, frameCount: Int) {
        hopLength = configuration.hopLength
        fftSize = configuration.fftSize
        padLeft = configuration.fftSize / 2
        self.sampleCount = sampleCount
        self.synthesisWindow = synthesisWindow
        let frames = max(1, frameCount)
        let paddedLength = (frames - 1) * hopLength + fftSize
        accumulator = [Float](repeating: 0, count: paddedLength)
        envelope = [Float](repeating: 0, count: paddedLength)
    }

    /// Adds one synthesis frame at `frameIndex * hopLength`, accumulating both the
    /// windowed samples and the squared-window envelope.
    mutating func add(frame: [Float], frameIndex: Int) {
        let start = frameIndex * hopLength
        for index in 0 ..< fftSize {
            let position = start + index
            let weight = synthesisWindow[index]
            accumulator[position] += frame[index] * weight
            envelope[position] += weight * weight
        }
    }

    /// Normalizes by the envelope and trims to the original sample count.
    func finalize() -> [Float] {
        var output = [Float](repeating: 0, count: sampleCount)
        let epsilon: Float = 1e-8
        for index in 0 ..< sampleCount {
            let position = padLeft + index
            guard position < accumulator.count else { break }
            let weight = envelope[position]
            output[index] = weight > epsilon ? accumulator[position] / weight : 0
        }
        return output
    }
}
