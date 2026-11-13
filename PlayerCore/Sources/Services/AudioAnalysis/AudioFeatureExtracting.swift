// AudioFeatureExtracting — the fakeable seam for offline audio-feature analysis.
//
// One track in, three numbers out: tempo (BPM), loudness (RMS energy) and timbre
// (spectral centroid, exposed as "brightness"). The features describe the FILE,
// not a listener, so they are profile-independent and cacheable indefinitely
// against a `(fileSize, mtime)` fingerprint — todo 11's `AudioAnalysisService`
// persists them into `trackAudioFeature`; this seam itself writes nothing.
//
// OFFLINE analysis only. A conformer opens its own decoder and MUST NEVER touch
// the live engine, its render callback, or the tap closure — the audio-thread
// invariants are about that path, and this one deliberately never reaches it.
//
// PlayerCore portability: Foundation only.
import Foundation

/// The analytical features one offline pass extracts from a single audio file.
///
/// Mirrors the analytical columns of `TrackAudioFeatureRecord`; the fingerprint
/// and versioning columns are added by the persisting layer, not here.
public struct AudioFeatureResult: Sendable, Equatable {
    /// Estimated tempo in beats per minute, or `nil` when the detector's
    /// confidence gate rejected the estimate — silence, ambient textures and
    /// spoken word have no periodic onset structure to lock onto, and reporting
    /// `nil` is strictly better than reporting a confident wrong number.
    public let bpm: Double?

    /// Mean RMS loudness normalized to `0...1`, where `1.0` is a full-scale sine
    /// (see ``AudioFeatureExtractor/fullScaleRMS``). Digital silence is `0`.
    public let energy: Double

    /// Mean spectral centroid, log-normalized to `0...1` across the
    /// `20 Hz … 20 kHz` band. Bass-heavy material sits low, cymbal-heavy
    /// material sits high; digital silence is `0`.
    public let brightness: Double

    public init(bpm: Double?, energy: Double, brightness: Double) {
        self.bpm = bpm
        self.energy = energy
        self.brightness = brightness
    }
}

/// Typed failures from an audio-feature pass.
///
/// Decoder failures are wrapped rather than rethrown so a consumer of this seam
/// never has to import `Decoding` to triage them; `reason` carries the
/// underlying description for logs.
public enum AudioFeatureError: Error, Equatable, Sendable {
    /// The file could not be opened, or decoding failed part-way through.
    case decodeFailed(url: URL, reason: String)

    /// The decoder opened but reported a format the analyzer cannot use — a
    /// non-positive sample rate, zero channels, or a layout that will not
    /// convert to deinterleaved float32.
    case unreadableStream(url: URL)
}

/// A `Sendable` seam that extracts an ``AudioFeatureResult`` from an audio file.
public protocol AudioFeatureExtracting: Sendable {
    /// Decodes `url` once, in bounded windows, and returns its features.
    ///
    /// The whole file is never materialised in memory: samples are pulled a
    /// window at a time and folded into running accumulators, so cost is flat in
    /// track length apart from the onset envelope (one `Float` per ~11.6 ms).
    ///
    /// Cancellation is checked between windows, so a cancelled task stops
    /// promptly instead of decoding to the end.
    ///
    /// - Throws: ``AudioFeatureError`` on unreadable or undecodable input, and
    ///   `CancellationError` when the calling task is cancelled.
    func extractFeatures(from url: URL) async throws -> AudioFeatureResult
}
