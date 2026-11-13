// SFBDecoderProvider — the production decoder backend (SFBAudioEngine).
//
// Wraps SFBAudioEngine's `AudioDecoder` (universal PCM codecs) and routes DSD
// sources through `DSDPCMDecoder` so the output is ALWAYS linear PCM. Every SFB
// / Foundation error is caught and re-thrown as a typed ``DecodingError`` — a
// corrupt, truncated, unsupported or unreadable file can never crash a caller.
//
// `@preconcurrency import` keeps SFB's not-yet-Sendable-annotated types from
// tripping Swift 6 strict concurrency. SFB's own decode protocol is *also* named
// `PCMDecoding`, so it is referenced fully qualified as
// `SFBAudioEngine.PCMDecoding` to disambiguate from this module's protocol.
//
// This file imports only AVFAudio + Foundation + SFBAudioEngine; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation
@preconcurrency import SFBAudioEngine

/// A ``DecoderProviding`` backed by SFBAudioEngine.
///
/// Stateless and therefore `Sendable`: a single value can vend decoders for any
/// number of URLs. The decoders it returns are thread-confined (not `Sendable`).
public struct SFBDecoderProvider: DecoderProviding {
    public init() {}

    public func makeDecoder(for url: URL) throws -> any PCMDecoding {
        try Self.preflight(url)
        let backend: any SFBAudioEngine.PCMDecoding = if Self.isDSD(url) {
            try Self.openDSDDecoder(for: url)
        } else {
            try Self.openPCMDecoder(for: url)
        }
        return SFBDecoderAdapter(backend: backend, url: url)
    }

    public func makeDecoder(for source: DecoderSource) throws -> any PCMDecoding {
        let decoder = try makeDecoder(for: source.url)
        guard let frameRange = source.frameRange else { return decoder }
        return try Self.restrict(decoder, to: frameRange, url: source.url)
    }

    /// Lower-cased extensions handled by the PCM codecs *and* the DSD decoders.
    public static var supportedPathExtensions: Set<String> {
        let combined = AudioDecoder.supportedPathExtensions.union(dsdPathExtensions)
        return Set(combined.map { $0.lowercased() })
    }

    /// Lower-cased extensions routed to the DSD decoders.
    ///
    /// SFB registers `dff` only, but `dsdiff` is the same container under its
    /// long spelling and is what the library scanner walks. SFB opens it by
    /// content sniffing (a format match scores +75 against a threshold of 10),
    /// so the only thing missing was this routing decision — without it a
    /// `.dsdiff` file is handed to the PCM-only `AudioDecoder` registry, which
    /// has no DSD decoder in it at all and fails outright.
    public static var dsdPathExtensions: Set<String> {
        Set(DSDDecoder.supportedPathExtensions.map { $0.lowercased() }).union(["dsdiff"])
    }

    /// MIME types handled by the PCM codecs *and* the DSD decoders.
    public static var supportedMIMETypes: Set<String> {
        AudioDecoder.supportedMIMETypes.union(DSDDecoder.supportedMIMETypes)
    }

    // MARK: - Backend construction

    private static func isDSD(_ url: URL) -> Bool {
        dsdPathExtensions.contains(url.pathExtension.lowercased())
    }

    private static func openPCMDecoder(for url: URL) throws -> any SFBAudioEngine.PCMDecoding {
        do {
            let decoder = try AudioDecoder(url: url)
            try decoder.open()
            return decoder
        } catch {
            throw DecodingError.from(error, url: url)
        }
    }

    /// Opens the raw DSD stream FIRST so its native rate can be inspected, then
    /// wraps it in the PCM-converting decoder.
    ///
    /// `DSDPCMDecoder` converts DSD64 only (`SFBDSDPCMDecoder.mm:327`), and its
    /// own refusal is an `InvalidFormat` error indistinguishable from a corrupt
    /// stream — so the rate is checked here instead, producing the typed
    /// ``DecodingError/unsupportedSampleRate(url:detail:)``. DSD128/256/512 are
    /// REFUSED, never resampled. Handing an already-open decoder on is safe:
    /// `DSDPCMDecoder.open` re-opens only `if !_decoder.isOpen`.
    private static func openDSDDecoder(for url: URL) throws -> any SFBAudioEngine.PCMDecoding {
        do {
            let stream = try DSDDecoder(url: url)
            try stream.open()
            try rejectUnconvertibleDSDRate(of: stream, url: url)
            let decoder = try DSDPCMDecoder(decoder: stream)
            try decoder.open()
            return decoder
        } catch {
            throw DecodingError.from(error, url: url)
        }
    }

    /// Throws ``DecodingError/unsupportedSampleRate(url:detail:)`` unless `stream`
    /// is DSD64 — the one rate `DSDPCMDecoder` decimates to PCM.
    ///
    /// The comparison is against `dsd64SampleRate` (2 822 400 Hz) ALONE, matching
    /// SFB's own check byte for byte. The 48 kHz-based `dsd64SampleRateVariant`
    /// (3 072 000 Hz) is a DSD64 rate that SFB nevertheless refuses, so widening
    /// this gate to accept it would only move the failure later and untyped.
    private static func rejectUnconvertibleDSDRate(of stream: DSDDecoder, url: URL) throws {
        let rate = stream.processingFormat.sampleRate
        guard rate != Double(dsd64SampleRate) else { return }
        throw DecodingError.unsupportedSampleRate(url: url, detail: dsdRateLabel(rate))
    }

    /// A diagnostic token for a DSD rate (`"DSD128 (5644800 Hz)"`), never user copy.
    private static func dsdRateLabel(_ rate: Double) -> String {
        let hertz = UInt32(max(rate.rounded(), 0))
        guard let name = dsdRateNames[hertz] else { return "\(hertz) Hz" }
        return "\(name) (\(hertz) Hz)"
    }

    /// Both published DSD rate families (44.1 kHz- and 48 kHz-based), so a refusal
    /// names the rate the way the format does instead of printing bare hertz.
    private static let dsdRateNames: [UInt32: String] = [
        dsd64SampleRate: "DSD64",
        dsd128SampleRate: "DSD128",
        dsd256SampleRate: "DSD256",
        dsd512SampleRate: "DSD512",
        dsd64SampleRateVariant: "DSD64 (48 kHz base)",
        dsd128SampleRateVariant: "DSD128 (48 kHz base)",
        dsd256SampleRateVariant: "DSD256 (48 kHz base)",
        dsd512SampleRateVariant: "DSD512 (48 kHz base)",
    ]

    /// Wraps an already-open decoder in SFB's `AudioRegionDecoder` so only
    /// `frameRange` is decoded. `AudioRegionDecoder` opens its inner decoder on
    /// demand, so handing it the adapter's already-open backend is safe.
    private static func restrict(
        _ decoder: any PCMDecoding,
        to frameRange: Range<AVAudioFramePosition>,
        url: URL
    ) throws -> any PCMDecoding {
        guard let backed = decoder as? SFBDecoderAdapter else {
            throw DecodingError.unsupportedFormat(url: url)
        }
        let startFrame = max(frameRange.lowerBound, 0)
        do {
            let region = try AudioRegionDecoder(
                decoder: backed.sfbBackend,
                startFrame: startFrame,
                frameLength: regionFrameLength(from: startFrame, to: frameRange.upperBound, in: decoder, url: url)
            )
            try region.open()
            return SFBDecoderAdapter(backend: region, url: url)
        } catch {
            throw DecodingError.from(error, url: url)
        }
    }

    /// The `frameLength` to request of `AudioRegionDecoder`, clamped to what the
    /// stream actually holds, where **`-1` means "to end of stream"**.
    ///
    /// `AudioRegionDecoder` REFUSES an over-long region rather than shortening it
    /// (`SFBAudioRegionDecoder.m`: `_requestedFrameLength > decoderFrameLength -
    /// _startFrame` closes the decoder and returns an internal error), and it
    /// asserts `frameLength > 0 || frameLength == -1`. So both of the ordinary cue
    /// cases have to be resolved here: a sheet whose last `INDEX` overruns its audio
    /// file, and a `FILE` block's final segment, which carries no end at all and
    /// arrives as `AVAudioFramePosition.max`. Both land in the `-1` branch, which is
    /// how the region ends up reporting a SHORTENED `frameLength` instead of
    /// throwing. An unknown stream length (negative `available`) takes the same
    /// branch, which is the only safe reading of "decode what is there".
    private static func regionFrameLength(
        from startFrame: AVAudioFramePosition,
        to endFrame: AVAudioFramePosition,
        in decoder: any PCMDecoding,
        url: URL
    ) throws -> AVAudioFramePosition {
        let requested = endFrame - startFrame
        guard requested > 0 else { throw DecodingError.unsupportedFormat(url: url) }
        let available = decoder.frameLength - startFrame
        return requested >= available ? -1 : requested
    }

    /// Rejects unreadable / empty inputs with a typed error *before* SFB is
    /// asked to parse them, so missing files and zero-byte stubs never surface
    /// as opaque backend failures.
    private static func preflight(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw DecodingError.ioError(url: url, underlying: "file does not exist")
        }
        guard manager.isReadableFile(atPath: url.path) else {
            throw DecodingError.ioError(url: url, underlying: "file is not readable")
        }
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        if let size = (attributes?[.size] as? NSNumber)?.intValue, size == 0 {
            throw DecodingError.truncated(url: url)
        }
    }
}

// MARK: - SFB backend exposure

/// A decoder that carries the live SFBAudioEngine decoder behind it.
///
/// `package`-scoped on purpose: `AudioEngine` needs the backend OBJECT to hand to
/// `SFBAudioPlayer` (the URL-based enqueue re-opens the file through SFB's
/// PCM-only factory, which is why DSD and CUE regions never reach the player),
/// but no shell or app target has any business reaching an SFB type.
package protocol SFBBackedDecoding: PCMDecoding {
    var sfbBackend: any SFBAudioEngine.PCMDecoding { get }
}

// MARK: - Adapter: SFBAudioEngine.PCMDecoding -> this module's PCMDecoding

/// Adapts an SFBAudioEngine decoder to this module's ``PCMDecoding`` protocol,
/// translating every thrown SFB error into a typed ``DecodingError``.
final class SFBDecoderAdapter: PCMDecoding, SFBBackedDecoding {
    private let backend: any SFBAudioEngine.PCMDecoding
    private let url: URL

    package var sfbBackend: any SFBAudioEngine.PCMDecoding {
        backend
    }

    init(backend: any SFBAudioEngine.PCMDecoding, url: URL) {
        self.backend = backend
        self.url = url
    }

    var processingFormat: AVAudioFormat {
        backend.processingFormat
    }

    var sourceFormat: AVAudioFormat? {
        backend.sourceFormat
    }

    var frameLength: AVAudioFramePosition {
        backend.length
    }

    var framePosition: AVAudioFramePosition {
        backend.position
    }

    var supportsSeeking: Bool {
        backend.supportsSeeking
    }

    @discardableResult
    func decode(into buffer: AVAudioPCMBuffer, frameLength frames: AVAudioFrameCount) throws -> AVAudioFrameCount {
        do {
            try backend.decode(into: buffer, length: frames)
        } catch {
            // A known length we did not reach means the stream ended early.
            let length = backend.length
            if length > 0, backend.position < length {
                throw DecodingError.truncated(url: url)
            }
            throw DecodingError.from(error, url: url)
        }
        return buffer.frameLength
    }

    @discardableResult
    func seek(toFrame frame: AVAudioFramePosition) throws -> AVAudioFramePosition {
        do {
            try backend.seek(to: frame)
        } catch {
            throw DecodingError.from(error, url: url)
        }
        return backend.position
    }
}

// MARK: - Error mapping

private extension DecodingError {
    /// SFB `NSError` codes (`SFBAudioDecoderErrorCode` / `SFBDSDDecoderErrorCode`).
    /// Stable integers shared by both decoder error domains.
    enum SFBCode {
        static let unknownDecoder = 0
        static let invalidFormat = 1
        static let unsupportedFormat = 2
        static let internalError = 3
        static let decodingError = 4
        static let seekError = 5
    }

    /// Translates any SFB / Foundation error into a typed ``DecodingError``.
    static func from(_ error: Error, url: URL) -> DecodingError {
        if let typed = error as? DecodingError { return typed }
        let nsError = error as NSError

        if nsError.domain == AudioDecoder.ErrorDomain || nsError.domain == DSDDecoder.ErrorDomain {
            switch nsError.code {
            case SFBCode.unsupportedFormat, SFBCode.unknownDecoder:
                return .unsupportedFormat(url: url)
            case SFBCode.invalidFormat, SFBCode.decodingError:
                return .corruptedFile(url: url, reason: nsError.localizedDescription)
            default:
                return .ioError(url: url, underlying: nsError.localizedDescription)
            }
        }
        return .ioError(url: url, underlying: nsError.localizedDescription)
    }
}
