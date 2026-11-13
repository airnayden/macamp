// InstrumentalWriter — atomic `.m4a` encoder for separated instrumentals.
//
// The final stage of the offline separation pipeline: it takes the reconstructed
// instrumental as deinterleaved float32 PCM (44.1 kHz stereo — the model-native
// format produced by `Resampler` and the iSTFT/overlap-add stage) and encodes it
// to an `.m4a` container at one of two quality tiers (``InstrumentalRenderQuality``).
// `.lossless` is 24-bit Apple Lossless (ALAC) — an INTEGER codec, so the FIXED
// 24-bit source-depth (stated explicitly in the settings dict) is the quantisation
// grid: samples already representable at 24-bit survive byte-exact, arbitrary float
// samples are bounded by ≤ 1 LSB. `.standard` is 256 kbps AAC — smaller files,
// transparent for karaoke playback.
//
// Atomic-write contract (mirrors `SFBMetadataWriter`):
//
//   1. Encode to a hidden sibling temp file in the SAME directory as the final
//      path (same volume ⇒ the final rename is atomic).
//   2. Atomically publish the temp to the final path (`replaceItemAt` when a file
//      already exists there, otherwise a same-volume `moveItem` == `rename(2)`).
//
// If ANY step fails, the temp is removed and NOTHING partial is ever left at the
// final path — a concurrent reader (the cache / coordinator) never observes a
// half-written `.m4a`. ENOSPC is surfaced as `SeparationError.diskFull`; every
// other write failure maps to `SeparationError.encodeFailed`.
//
// This is OFFLINE (pre-render) processing, NOT audio-thread code: it allocates
// freely and drives `AVAudioFile`. PlayerCore portability: imports only system
// audio frameworks + Foundation/Darwin (no AppKit/UIKit).
import AudioToolbox
import AVFAudio
import Darwin
import Foundation

/// Encodes reconstructed instrumental PCM to an atomic `.m4a` at a selectable
/// quality tier — 24-bit Apple Lossless or 256 kbps AAC.
///
/// The output is always 44.1 kHz, 2 channels; the codec is chosen per call via
/// ``InstrumentalRenderQuality`` (default `.lossless`). Input buffers must be in the
/// writer's ``processingFormat`` (deinterleaved float32 at 44.1 kHz / stereo — what
/// `Resampler` and `decodeAll` both vend); the exact `frameLength` of the input is
/// preserved end-to-end.
public struct InstrumentalWriter: Sendable {
    /// The ALAC output sample rate (model-native).
    public static let sampleRate: Double = 44100
    /// The ALAC output channel count (model-native).
    public static let channelCount: AVAudioChannelCount = 2
    /// The FIXED ALAC source bit depth. ALAC is an integer codec; this is the
    /// quantisation grid the round-trip precision bounds are stated against.
    public static let bitDepth: Int = 24
    /// The AAC bit rate used by ``InstrumentalRenderQuality/standard`` (256 kbps).
    public static let standardBitRate: Int = 256_000

    public init() {}

    /// The float32 PCM format callers must supply — deinterleaved, 44.1 kHz,
    /// stereo. Equal to the `AVAudioFile` writing processing format, so a matching
    /// buffer needs no conversion before ``write(_:to:)``.
    public static var processingFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)
    }

    /// Encodes `buffer` to an `.m4a` at `destination`, atomically.
    ///
    /// - Parameters:
    ///   - buffer: Deinterleaved float32 PCM in ``processingFormat``. Its exact
    ///     `frameLength` is preserved in the encoded file.
    ///   - destination: The final `.m4a` URL. Its parent directory must already
    ///     exist (the cache creates it); nothing is written there until the encode
    ///     succeeds, and the publish is atomic.
    ///   - quality: The encode tier — ``InstrumentalRenderQuality/lossless`` (24-bit
    ///     ALAC, the default) or ``InstrumentalRenderQuality/standard`` (256 kbps AAC).
    /// - Throws: ``SeparationError/diskFull`` when the device is out of space,
    ///   ``SeparationError/encodeFailed`` for any other encode/publish failure.
    public func write(
        _ buffer: AVAudioPCMBuffer,
        to destination: URL,
        quality: InstrumentalRenderQuality = .lossless
    ) throws {
        let manager = FileManager.default
        let temp = Self.makeTempURL(for: destination)
        do {
            try Self.encode(buffer, to: temp, quality: quality)
            try Self.publish(temp: temp, to: destination, manager: manager)
        } catch {
            try? manager.removeItem(at: temp)
            throw Self.mapWriteError(error)
        }
    }

    // MARK: - Encode (float32 → ALAC / AAC)

    /// Writes `buffer` to `url` at the given `quality` tier, selecting the codec via
    /// ``settings(for:)``.
    static func encode(_ buffer: AVAudioPCMBuffer, to url: URL, quality: InstrumentalRenderQuality) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings(for: quality))
        try file.write(from: buffer)
    }

    /// The `AVAudioFile` settings dict for a quality tier. `.lossless` is 24-bit
    /// Apple Lossless — `AVEncoderBitDepthHintKey` is the key that actually sets the
    /// ALAC source depth, `AVLinearPCMBitDepthKey` states the same 24-bit intent
    /// explicitly. `.standard` is 256 kbps AAC and carries no bit-depth keys (AAC is
    /// not an integer codec). Both are 44.1 kHz stereo in an `.m4a` container.
    static func settings(for quality: InstrumentalRenderQuality) -> [String: Any] {
        switch quality {
        case .lossless:
            [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channelCount),
                AVEncoderBitDepthHintKey: bitDepth,
                AVLinearPCMBitDepthKey: bitDepth,
            ]
        case .standard:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channelCount),
                AVEncoderBitRateKey: standardBitRate,
            ]
        }
    }

    // MARK: - Atomic publish

    /// Publishes `temp` to `destination` atomically: an in-place `replaceItemAt`
    /// when a file already exists there, otherwise a same-volume `moveItem`
    /// (`rename(2)`). Either way `temp` is consumed on success.
    static func publish(temp: URL, to destination: URL, manager: FileManager) throws {
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temp)
        } else {
            try manager.moveItem(at: temp, to: destination)
        }
    }

    /// A hidden sibling of `url`, KEEPING the `.m4a` extension so `AVAudioFile`
    /// writes the correct container. Same directory ⇒ same volume ⇒ the publish is
    /// an atomic rename.
    static func makeTempURL(for url: URL) -> URL {
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let name = ".macamp-instrumental-\(UUID().uuidString).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    // MARK: - Error mapping

    /// Maps a raw encode/publish failure onto the typed separation ladder: ENOSPC
    /// (Cocoa or POSIX, at any nesting depth) ⇒ ``SeparationError/diskFull``,
    /// everything else ⇒ ``SeparationError/encodeFailed``.
    static func mapWriteError(_ error: Error) -> SeparationError {
        isOutOfSpace(error) ? .diskFull : .encodeFailed
    }

    /// Whether `error` (or any error it wraps via `NSUnderlyingErrorKey`) is an
    /// out-of-space condition — Cocoa `fileWriteOutOfSpace` or POSIX `ENOSPC`.
    static func isOutOfSpace(_ error: Error) -> Bool {
        var current: Error? = error
        var depth = 0
        while let value = current, depth < 8 {
            let nsError = value as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
                return true
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return false
    }
}

/// Task-confined incremental encoder. Unfinished sessions remove their hidden
/// output; only finish closes the encoder and atomically publishes a complete file.
final class InstrumentalWriteStream {
    private var file: AVAudioFile?
    private let temporary: URL
    private let destination: URL

    init(to destination: URL, quality: InstrumentalRenderQuality) throws {
        self.destination = destination
        temporary = InstrumentalWriter.makeTempURL(for: destination)
        do {
            file = try AVAudioFile(forWriting: temporary, settings: InstrumentalWriter.settings(for: quality))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw InstrumentalWriter.mapWriteError(error)
        }
    }

    deinit {
        file = nil
        try? FileManager.default.removeItem(at: temporary)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw SeparationError.encodeFailed }
        do {
            try file.write(from: buffer)
        } catch {
            throw InstrumentalWriter.mapWriteError(error)
        }
    }

    func finish() throws {
        guard file != nil else { throw SeparationError.encodeFailed }
        file = nil
        do {
            try InstrumentalWriter.publish(temp: temporary, to: destination, manager: .default)
        } catch {
            throw InstrumentalWriter.mapWriteError(error)
        }
    }
}
