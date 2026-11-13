// AudioFeaturePass — one file, one streaming decode, three features.
//
// The pass owns the loop; ``SpectralWindowAnalyzer`` owns the per-window FFT and
// ``TempoEstimator`` owns the final tempo search. Everything here is synchronous
// value work so the caller decides where it runs — ``AudioFeatureExtractor`` runs
// it detached at utility priority.
//
// Memory: only one hop of PCM and one analysis window exist at a time. The single
// thing that grows with track length is the onset envelope, at one `Float` per
// hop — ~86 per second, so ~100 KB for a five-minute track.
//
// PlayerCore portability: AVFAudio + Accelerate + Foundation + Decoding.
import Accelerate
import AVFAudio
import Decoding
import Foundation

/// A single track's feature extraction, start to finish.
struct AudioFeaturePass {
    let decoderProvider: any DecoderProviding
    let analyzer: SpectralWindowAnalyzer

    /// Decodes `url` in bounded windows and returns its features.
    ///
    /// - Throws: ``AudioFeatureError`` on unreadable input, `CancellationError`
    ///   when the surrounding task is cancelled — checked before every window, so
    ///   a cancelled pass stops within one hop (~11.6 ms of audio) rather than
    ///   decoding to the end.
    func run(url: URL) async throws -> AudioFeatureResult {
        let windowSize = SpectralWindowAnalyzer.windowSize
        let hopSize = SpectralWindowAnalyzer.hopSize
        let stream = try await openStream(url: url, capacity: AVAudioFrameCount(hopSize))

        var accumulator = FeatureAccumulator(sampleRate: stream.sampleRate)
        var hop = [Float](repeating: 0, count: hopSize)
        var window = [Float](repeating: 0, count: windowSize)
        var consumed = 0
        // The first analysis is due once the window is full for the first time;
        // every later one a hop after its predecessor.
        var nextAnalysisAt = windowSize

        while true {
            try Task.checkCancellation()
            let produced = try stream.readMono(into: &hop)
            if produced == 0 { break }
            accumulator.addSamples(hop, count: produced)
            append(hop, count: produced, to: &window)
            consumed += produced
            // `readMono` never yields more than one hop, so this fires at most once.
            while consumed >= nextAnalysisAt {
                analyze(window, sampleRate: stream.sampleRate, into: &accumulator)
                nextAnalysisAt += hopSize
            }
        }
        return accumulator.finish()
    }

    // MARK: Private

    /// Opens the decoder through ``DecoderOpenGate/shared``, which is the only
    /// reason this is `async`: a page fans out `concurrencyCap` passes at once,
    /// and an ungated first MP3 construction from several of them at the same
    /// instant faults inside mpg123. The gate is released as soon as the header
    /// is parsed — the decode loop below runs fully parallel, as before.
    private func openStream(url: URL, capacity: AVAudioFrameCount) async throws -> MonoSampleStream {
        let decoder: any PCMDecoding
        do {
            decoder = try await DecoderOpenGate.shared.open(url, with: decoderProvider)
        } catch {
            throw AudioFeatureError.decodeFailed(url: url, reason: error.localizedDescription)
        }
        analyzer.reset()
        return try MonoSampleStream(decoder: decoder, url: url, capacity: capacity)
    }

    private func analyze(_ window: [Float], sampleRate: Double, into accumulator: inout FeatureAccumulator) {
        let measured = window.withUnsafeBufferPointer { buffer -> (flux: Float, centroidHz: Double?) in
            guard let base = buffer.baseAddress else { return (0, nil) }
            return analyzer.analyze(base, sampleRate: sampleRate)
        }
        accumulator.addWindow(flux: measured.flux, centroidHz: measured.centroidHz)
    }

    /// Slides `window` left by `count` and writes the new samples at its tail, so
    /// consecutive analyses see a 50 %-overlapped view without reallocating.
    private func append(_ source: [Float], count: Int, to window: inout [Float]) {
        let size = window.count
        let taken = min(count, size)
        for index in 0 ..< (size - taken) {
            window[index] = window[index + taken]
        }
        for index in 0 ..< taken {
            window[size - taken + index] = source[count - taken + index]
        }
    }
}

/// Running totals for one pass — streaming by construction.
struct FeatureAccumulator {
    let sampleRate: Double

    private var onsetEnvelope: [Float] = []
    private var squaredSum = 0.0
    private var sampleCount = 0
    private var centroidSum = 0.0
    private var centroidCount = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Folds a decoded hop into the exact whole-track mean square, so energy is
    /// measured over every sample rather than only over analysis windows.
    mutating func addSamples(_ samples: [Float], count: Int) {
        guard count > 0 else { return }
        var sum: Float = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_svesq(base, 1, &sum, vDSP_Length(count))
        }
        squaredSum += Double(sum)
        sampleCount += count
    }

    mutating func addWindow(flux: Float, centroidHz: Double?) {
        onsetEnvelope.append(flux)
        guard let centroidHz else { return }
        centroidSum += centroidHz
        centroidCount += 1
    }

    func finish() -> AudioFeatureResult {
        AudioFeatureResult(
            bpm: TempoEstimator.estimateBPM(
                envelope: onsetEnvelope,
                frameRate: sampleRate / Double(SpectralWindowAnalyzer.hopSize)
            ),
            energy: normalizedEnergy(),
            brightness: normalizedBrightness()
        )
    }

    // MARK: Private

    private func normalizedEnergy() -> Double {
        guard sampleCount > 0 else { return 0 }
        let rms = (squaredSum / Double(sampleCount)).squareRoot()
        return min(1, max(0, rms / AudioFeatureExtractor.fullScaleRMS))
    }

    private func normalizedBrightness() -> Double {
        guard centroidCount > 0 else { return 0 }
        let centroid = centroidSum / Double(centroidCount)
        let floorHz = AudioFeatureExtractor.brightnessFloorHz
        let ceilingHz = AudioFeatureExtractor.brightnessCeilingHz
        guard centroid > floorHz else { return 0 }
        return min(1, max(0, log(centroid / floorHz) / log(ceilingHz / floorHz)))
    }
}
