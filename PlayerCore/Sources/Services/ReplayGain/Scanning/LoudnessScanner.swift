//
//  LoudnessScanner.swift
//  MacAMP PlayerCore — Services
//
//  The production ``ReplayGainScanning``: EBU R128 / BS.1770-4 integrated
//  loudness + BS.1770-4 true peak, synthesized into ReplayGain 2.0 values for a
//  file that carries no REPLAYGAIN_* tags.
//
//  A value type rather than an actor. ``AudioFeatureExtractor`` is an actor
//  because it pools an FFT setup between files; nothing here is poolable —
//  ``LoudnessAnalyzer`` owns per-track filter memory and one instance serves
//  exactly one pass — so a stateless struct lets a library-wide pass fan out
//  without funnelling every scan through one executor.
//
//  The work itself is `Task.detached(priority: .utility)`: heavy offline DSP has
//  no business on the caller's executor, and utility is the tier the separation,
//  lyrics and feature passes already use. A detached task does NOT inherit
//  cancellation and `Task.value` is not cancellation-aware, so
//  `withTaskCancellationHandler` is what makes a cancelled caller actually reach
//  the decode loop — the ``AudioFeatureExtractor`` construction.
//
//  This type NEVER touches the live engine, the render callback, or the tap: it
//  opens its own decoder and reads the file from scratch.
//
//  PlayerCore portability: AVFAudio + Decoding + Foundation + Metadata.
//

import AVFAudio
import Decoding
import Foundation
import Metadata

// MARK: - LoudnessMeasuring

/// Measures one file's integrated loudness, true peak, and gating blocks.
///
/// The wider seam behind ``ReplayGainScanning``: the batch service needs the
/// gated block set for album pooling, which the two-number ``ReplayGain`` shape
/// cannot carry. Conformers are `Sendable` value types so a page can fan out
/// without sharing state.
public protocol LoudnessMeasuring: Sendable {
    /// Scans `url` and returns its measurement.
    ///
    /// - Throws: ``LoudnessScanError`` when the file cannot be decoded, or
    ///   `CancellationError` when the calling task is cancelled.
    func measureLoudness(of url: URL) async throws -> LoudnessScanResult
}

// MARK: - LoudnessScanner

/// The shipped ``ReplayGainScanning`` / ``LoudnessMeasuring``.
public struct LoudnessScanner: ReplayGainScanning, LoudnessMeasuring {
    /// Frames pulled from the decoder per window.
    ///
    /// Comfortably above one 100 ms sub-block at every supported rate (4 800
    /// frames at 48 kHz, 19 200 at 192 kHz would each straddle a window — which
    /// is fine: ``LoudnessAnalyzer`` carries partial sub-blocks across calls, so
    /// the window size is a memory/syscall trade-off and nothing else). At
    /// stereo float this is 64 KB of PCM in flight per scan.
    public static let defaultBlockFrames: AVAudioFrameCount = 8192

    private let decoderProvider: any DecoderProviding
    private let blockFrames: AVAudioFrameCount

    /// - Parameters:
    ///   - decoderProvider: The decode backend. Opened through
    ///     ``DecoderOpenGate/shared`` inside the pass.
    ///   - blockFrames: Decode window size, free so a test can prove the result
    ///     does not depend on it.
    public init(
        decoderProvider: any DecoderProviding,
        blockFrames: AVAudioFrameCount = LoudnessScanner.defaultBlockFrames
    ) {
        self.decoderProvider = decoderProvider
        self.blockFrames = max(1, blockFrames)
    }

    public func measureLoudness(of url: URL) async throws -> LoudnessScanResult {
        let pass = LoudnessScanPass(decoderProvider: decoderProvider, blockFrames: blockFrames)
        let work = Task.detached(priority: .utility) { try await pass.run(url: url) }
        let outcome = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        return try outcome.get()
    }

    /// Synthesizes ReplayGain 2.0 tags from a fresh measurement.
    ///
    /// The result flows through the unchanged ``ReplayGainCalculator`` path, so
    /// a scanned file and a tagged one are indistinguishable downstream. Album
    /// fields are absent — they belong to a group, and a single-file scan has no
    /// group to speak for (``LoudnessScanService`` fills them once every member
    /// of an album has been measured).
    public func scan(url: URL) async throws -> ReplayGain {
        try await measureLoudness(of: url).replayGain
    }
}
