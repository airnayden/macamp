//
//  FLACStreamDigestPass.swift
//  MacAMP PlayerCore — Services
//
//  One verification pass over one FLAC file.
//
//  The whole stream is NEVER materialised. Exactly `windowFrames` frames exist
//  at a time — one decoder scratch buffer plus one canonical-byte scratch
//  array, both allocated once and reused — so a 74-minute 24-bit stereo album
//  file costs ~120 KB of working set instead of ~1.5 GB. That is why this is
//  neither `PCMDecoding.decodeAll()` nor `Separation.WindowedFloatDecoder`:
//  both concatenate every block into one whole-track buffer.
//
//  It is also not ``PlanarSampleStream``, which normalises to float32. The
//  digest is defined over the source's INTEGER samples, so this pass reads the
//  decoder's native integer containers directly (see ``CanonicalSampleLayout``).
//
//  PlayerCore portability: AVFAudio + CryptoKit + Decoding + Foundation.
//

import AVFAudio
import CryptoKit
import Decoding
import Foundation

/// Decodes one file end to end and folds its canonical samples into an MD5.
///
/// A `Sendable` value type holding only the provider and the window size: the
/// decoder itself is opened inside ``run(url:)``, on whatever executor the
/// caller detached onto, and never escapes it.
struct FLACStreamDigestPass {
    /// The all-zero STREAMINFO checksum, whose defined meaning is "no MD5 was
    /// recorded" rather than "the MD5 of this stream happens to be zero".
    static let unsetChecksum = Data(repeating: 0, count: 16)

    let decoderProvider: any DecoderProviding
    let windowFrames: AVAudioFrameCount

    func run(url: URL) throws -> FLACIntegrityResult {
        let decoder = try open(url)
        guard let stored = (decoder as? any FLACStreamMD5Providing)?.flacStreamMD5 else {
            throw FLACIntegrityError.notFLAC(url: url)
        }
        guard let layout = CanonicalSampleLayout(format: decoder.processingFormat) else {
            throw FLACIntegrityError.unsupportedLayout(url: url)
        }
        let computed = try digest(decoder, layout: layout, url: url)

        if stored == Self.unsetChecksum {
            return .noStoredMD5(computed: computed)
        }
        return stored == computed ? .match : .mismatch(stored: stored, computed: computed)
    }

    // MARK: Private

    private func open(_ url: URL) throws -> any PCMDecoding {
        do {
            return try decoderProvider.makeDecoder(for: url)
        } catch {
            throw FLACIntegrityError.unreadable(url: url, reason: error.localizedDescription)
        }
    }

    private func digest(
        _ decoder: any PCMDecoding,
        layout: CanonicalSampleLayout,
        url: URL
    ) throws -> Data {
        let frames = max(windowFrames, 1)
        guard let block = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: frames) else {
            throw FLACIntegrityError.unsupportedLayout(url: url)
        }
        var scratch = [UInt8](repeating: 0, count: Int(frames) * layout.frameByteCount)
        var context = Insecure.MD5()

        while true {
            try Task.checkCancellation()
            let produced = try pull(decoder, into: block, url: url)
            if produced == 0 { break }
            guard let byteCount = layout.pack(block, into: &scratch) else {
                throw FLACIntegrityError.unsupportedLayout(url: url)
            }
            scratch.withUnsafeBytes { raw in
                context.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0 ..< byteCount]))
            }
        }
        return Data(context.finalize())
    }

    private func pull(
        _ decoder: any PCMDecoding,
        into block: AVAudioPCMBuffer,
        url: URL
    ) throws -> AVAudioFrameCount {
        do {
            return try decoder.decode(into: block, frameLength: block.frameCapacity)
        } catch {
            throw FLACIntegrityError.decodeFailed(url: url, reason: error.localizedDescription)
        }
    }
}
