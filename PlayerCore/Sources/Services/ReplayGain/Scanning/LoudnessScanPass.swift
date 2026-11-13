//
//  LoudnessScanPass.swift
//  MacAMP PlayerCore — Services
//
//  One file, one streaming decode, one BS.1770-4 measurement + true peak.
//
//  The pass owns the loop; ``LoudnessAnalyzer`` owns the K-weighting and gating
//  and ``TruePeakMeter`` owns the 4× oversampling. Both are fed the SAME planar
//  window, so the two readings describe the same samples by construction rather
//  than by two decodes that could drift.
//
//  Memory is flat in track length: one decode window of PCM at a time, plus the
//  gated block set the caller asked for (10 values per second of programme, so
//  ~3 000 `Double`s for a five-minute track).
//
//  Everything here is synchronous value work apart from the gated open, so the
//  caller decides where it runs — ``LoudnessScanner`` runs it detached at utility
//  priority.
//
//  PlayerCore portability: AVFAudio + Decoding + DSP + Foundation.
//

import AVFAudio
import Decoding
import DSP
import Foundation

/// A single track's loudness scan, start to finish.
struct LoudnessScanPass {
    let decoderProvider: any DecoderProviding
    let blockFrames: AVAudioFrameCount

    /// Decodes `url` in bounded windows and returns its loudness + true peak.
    ///
    /// - Throws: ``LoudnessScanError`` on unreadable input, `CancellationError`
    ///   when the surrounding task is cancelled — checked before every window, so
    ///   a cancelled pass stops within one block rather than decoding to the end.
    func run(url: URL) async throws -> LoudnessScanResult {
        let stream = try await openStream(url: url)
        let analyzer = LoudnessAnalyzer(
            sampleRate: stream.sampleRate,
            channelCount: stream.channelCount
        )
        let meter = TruePeakMeter(channelCount: stream.channelCount)

        while true {
            try Task.checkCancellation()
            let produced = try stream.read { channels, frameCount in
                analyzer.append(channels: channels, frameCount: frameCount)
                for (index, samples) in channels.enumerated() {
                    meter.process(samples, count: frameCount, channel: index)
                }
            }
            if produced == 0 { break }
        }

        return LoudnessScanResult(
            measurement: analyzer.finish(),
            truePeak: Double(meter.measurement.linear)
        )
    }

    // MARK: Private

    /// Opens the decoder through ``DecoderOpenGate/shared``, which is the only
    /// reason this is `async`: a page fans out ``LoudnessScanService/concurrencyCap``
    /// scans at once, and an ungated first MP3 construction from several of them
    /// at the same instant faults inside mpg123. The gate is released as soon as
    /// the header is parsed — the decode loop above runs fully parallel.
    private func openStream(url: URL) async throws -> PlanarSampleStream {
        let decoder: any PCMDecoding
        do {
            decoder = try await DecoderOpenGate.shared.open(url, with: decoderProvider)
        } catch {
            throw LoudnessScanError.decodeFailed(url: url, reason: error.localizedDescription)
        }
        return try PlanarSampleStream(decoder: decoder, url: url, capacity: blockFrames)
    }
}
