//
//  IntegrityCheckService.swift
//  MacAMP PlayerCore — Services
//
//  Proves (or disproves) that a file still decodes to the samples it was
//  encoded from.
//
//  The work is `Task.detached(priority: .utility)` — a full decode has no
//  business on the caller's executor, and utility is the tier the separation,
//  loudness and feature passes already use. A detached task does NOT inherit
//  cancellation and `Task.value` is not cancellation-aware, so
//  `withTaskCancellationHandler` is what makes a cancelled caller actually
//  reach the decode loop (the ``LoudnessScanner`` construction).
//
//  This type NEVER touches the live engine, the render callback, or the tap:
//  it opens its own decoder and reads the file from scratch.
//
//  PlayerCore portability: AVFAudio + Decoding + Foundation.
//

import AVFAudio
import Decoding
import Foundation

// MARK: - FLACIntegrityVerifying

/// Verifies a FLAC stream against the checksum stored in its STREAMINFO block.
public protocol FLACIntegrityVerifying: Sendable {
    /// Decodes `url` in full and compares the result with its stored checksum.
    ///
    /// - Throws: ``FLACIntegrityError`` when no verdict can be reached, or
    ///   `CancellationError` when the calling task is cancelled.
    func verifyFLAC(url: URL) async throws -> FLACIntegrityResult
}

// MARK: - IntegrityCheckService

/// The shipped ``FLACIntegrityVerifying``.
public struct IntegrityCheckService: FLACIntegrityVerifying {
    /// Frames pulled from the decoder per window.
    ///
    /// The window size is a memory/syscall trade-off and nothing else — the
    /// digest is a running fold, so it cannot depend on where the block
    /// boundaries fall (`FLACMD5VerificationTests.windowSizeDoesNotChangeTheDigest`
    /// pins that). At 24-bit stereo this is 48 KB of canonical bytes plus a
    /// 64 KB decoder buffer in flight per verification.
    public static let defaultWindowFrames: AVAudioFrameCount = 8192

    private let decoderProvider: any DecoderProviding
    private let windowFrames: AVAudioFrameCount

    /// - Parameters:
    ///   - decoderProvider: The decode backend. Must vend decoders that expose
    ///     ``FLACStreamMD5Providing``, which the shipped ``SFBDecoderProvider``
    ///     does for every codec it opens.
    ///   - windowFrames: Decode window size, free so a test can prove the
    ///     digest does not depend on it.
    public init(
        decoderProvider: any DecoderProviding = SFBDecoderProvider(),
        windowFrames: AVAudioFrameCount = IntegrityCheckService.defaultWindowFrames
    ) {
        self.decoderProvider = decoderProvider
        self.windowFrames = max(1, windowFrames)
    }

    public func verifyFLAC(url: URL) async throws -> FLACIntegrityResult {
        let pass = FLACStreamDigestPass(decoderProvider: decoderProvider, windowFrames: windowFrames)
        let work = Task.detached(priority: .utility) { try pass.run(url: url) }
        let outcome = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        return try outcome.get()
    }
}
