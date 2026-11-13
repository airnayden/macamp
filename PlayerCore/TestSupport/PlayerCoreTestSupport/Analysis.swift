// Analysis — sample-domain measurement helpers for offline-rendered buffers.
//
// These are the assertion primitives every engine TDD suite uses: spectral peak
// detection (vDSP FFT), level metering (RMS / dBFS / peak), gapless-continuity
// checks, and clip detection. Operates on non-interleaved float buffers.
import Accelerate
import AVFAudio
import Foundation

/// Static measurement helpers operating on `AVAudioPCMBuffer`s.
public enum Analysis {
    /// The dominant spectral bin of channel 0, via a real FFT (vDSP).
    ///
    /// A Hann window is applied to reduce spectral leakage; the DC bin is
    /// skipped. The input is zero-padded (or truncated) to `fftSize`.
    ///
    /// - Parameters:
    ///   - buffer: The rendered samples to analyze.
    ///   - fftSize: FFT length (power of two; default 4096).
    /// - Returns: The peak `bin` index and its corresponding `frequency` in Hz.
    public static func peakBin(
        buffer: AVAudioPCMBuffer,
        fftSize: Int = 4096
    ) -> (bin: Int, frequency: Double) {
        guard
            let channel = buffer.floatChannelData?[0],
            buffer.frameLength > 0,
            fftSize >= 2
        else { return (0, 0) }

        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return (0, 0)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let halfSize = fftSize / 2

        // Windowed, zero-padded input.
        var windowed = [Float](repeating: 0, count: fftSize)
        let inputCount = min(Int(buffer.frameLength), fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        for frame in 0 ..< inputCount {
            windowed[frame] = channel[frame] * window[frame]
        }

        var realParts = [Float](repeating: 0, count: halfSize)
        var imagParts = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        realParts.withUnsafeMutableBufferPointer { realBuf in
            imagParts.withUnsafeMutableBufferPointer { imagBuf in
                guard
                    let realBase = realBuf.baseAddress,
                    let imagBase = imagBuf.baseAddress
                else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                windowed.withUnsafeBufferPointer { inputBuf in
                    guard let inputBase = inputBuf.baseAddress else { return }
                    inputBase.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfSize
                    ) { reinterpreted in
                        vDSP_ctoz(reinterpreted, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Find the peak, skipping the DC bin (index 0).
        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        magnitudes.withUnsafeBufferPointer { mags in
            guard let base = mags.baseAddress, halfSize > 1 else { return }
            vDSP_maxvi(base.advanced(by: 1), 1, &maxValue, &maxIndex, vDSP_Length(halfSize - 1))
        }
        let bin = Int(maxIndex) + 1
        let frequency = Double(bin) * buffer.format.sampleRate / Double(fftSize)
        return (bin, frequency)
    }

    /// Linear RMS across all channels of the buffer.
    public static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var sumOfSquares: Float = 0
        for channel in 0 ..< channels {
            var channelRMS: Float = 0
            vDSP_rmsqv(data[channel], 1, &channelRMS, frames)
            sumOfSquares += channelRMS * channelRMS
        }
        return (sumOfSquares / Float(channels)).squareRoot()
    }

    /// RMS level expressed in dBFS (0 dBFS == RMS of 1.0). Silence == -inf.
    public static func dBFS(buffer: AVAudioPCMBuffer) -> Float {
        let value = rms(buffer: buffer)
        guard value > 0 else { return -.infinity }
        return 20 * log10(value)
    }

    /// Maximum absolute sample value across all channels.
    public static func peak(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var maxMagnitude: Float = 0
        for channel in 0 ..< channels {
            var channelPeak: Float = 0
            vDSP_maxmgv(data[channel], 1, &channelPeak, frames)
            maxMagnitude = max(maxMagnitude, channelPeak)
        }
        return maxMagnitude
    }

    /// Peak level expressed in dBFS (0 dBFS == peak of 1.0). Silence == -inf.
    public static func peakDBFS(buffer: AVAudioPCMBuffer) -> Float {
        let value = peak(buffer: buffer)
        guard value > 0 else { return -.infinity }
        return 20 * log10(value)
    }

    /// Detects a sudden zero-sample gap (an unexpected run of near-silence inside
    /// an otherwise non-silent signal) — the classic gapless-playback defect.
    ///
    /// A fully silent buffer is *not* a discontinuity (there is no signal to be
    /// interrupted). A pure tone's natural zero crossings are too short to count;
    /// only a run of `minimumGapFrames`+ consecutive near-zero samples flags true.
    ///
    /// - Parameters:
    ///   - buffer: Samples to inspect (channel 0).
    ///   - threshold: Absolute amplitude considered "zero" (default 1e-4).
    ///   - minimumGapFrames: Consecutive near-zero samples that constitute a gap.
    public static func hasDiscontinuity(
        buffer: AVAudioPCMBuffer,
        threshold: Float = 1e-4,
        minimumGapFrames: Int = 8
    ) -> Bool {
        guard let channel = buffer.floatChannelData?[0] else { return false }
        let frames = Int(buffer.frameLength)
        guard frames > minimumGapFrames else { return false }

        // Ignore intentional silence: there must be real signal to interrupt.
        guard peak(buffer: buffer) > threshold * 10 else { return false }

        var run = 0
        for frame in 0 ..< frames {
            if abs(channel[frame]) < threshold {
                run += 1
                if run >= minimumGapFrames { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// True if any sample's absolute value exceeds full scale (1.0).
    public static func isClipped(buffer: AVAudioPCMBuffer) -> Bool {
        peak(buffer: buffer) > 1.0
    }

    /// Convenience: total rendered duration in seconds.
    public static func duration(buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }
}
