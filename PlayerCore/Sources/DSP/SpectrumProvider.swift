import Foundation

/// Bridges the realtime audio producer to spectrum and metering consumers using
/// a pull model: the audio thread `ingest`s samples without waiting or allocating.
/// If a consumer owns a ring snapshot, the incoming metering block is dropped.
/// Non-real-time consumers may wait for ownership and pull on demand — the spectrum via
/// ``latestSpectrum()``, or a raw sample window via
/// ``latestWindow(channel:into:count:)``.
///
/// There is no callback or `DispatchQueue.main` hop — the consumer drives the
/// cadence (e.g. a display-link / timer in the UI layer).
///
/// Each metered channel owns a SEPARATE ring rather than one interleaved store.
/// That keeps the visualizer's channel-0 ring byte-identical to what it has
/// always been (same capacity, same write path, same non-destructive peek) and
/// makes the producer-side change purely additive: a second `memcpy` into a
/// second ring, never a re-layout of the first.
public final class SpectrumProvider: @unchecked Sendable {
    /// Channels the provider keeps a dedicated ring for. Channel 0 feeds the
    /// visualizer and the left meter; channel 1 feeds the right meter only.
    public static let meteredChannelCount = 2

    /// Samples each channel ring holds.
    public static let ringCapacity = 16384

    private let fftSize = 4096
    private let ring = SPSCRingBuffer(capacity: 16384)
    /// The second, dedicated channel-1 ring.
    ///
    /// Allocated unconditionally, including for mono playback: the only other
    /// moment it could be created is the first stereo tap callback, and that runs
    /// on the render thread where allocation is forbidden. 64 KB of always-resident
    /// storage is the cost of never mallocing in the tap.
    private let channel1Ring = SPSCRingBuffer(capacity: 16384)
    private let analyzer = SpectrumAnalyzer()
    private var window = [Float](repeating: 0, count: 4096)
    private var bands = [Float](repeating: 0, count: 128)

    public init() {}

    /// Producer (audio thread). Zero-allocation enqueue of `count` samples of
    /// channel 0.
    public func ingest(_ ptr: UnsafePointer<Float>, count: Int) {
        ring.write(ptr, count: count)
    }

    /// Producer (audio thread). Zero-allocation enqueue of `count` samples of
    /// channel 1.
    ///
    /// The producer calls this ONLY when the tap buffer actually carries a second
    /// channel. For a mono source this ring is simply never written, and its
    /// contents stay whatever the last stereo source left behind — which is why
    /// the consumer must decide for itself whether to read it (see
    /// ``latestWindow(channel:into:count:)``).
    public func ingestChannel1(_ ptr: UnsafePointer<Float>, count: Int) {
        channel1Ring.write(ptr, count: count)
    }

    /// Consumer (PULL). Peeks the most recent `fftSize` samples of channel 0 and
    /// returns the freshly computed 128-band spectrum. Reuses internal scratch
    /// buffers. Calls to this method must be serialized by the consumer.
    public func latestSpectrum() -> [Float] {
        window.withUnsafeMutableBufferPointer { buffer in
            ring.readLatest(into: buffer, count: fftSize)
        }
        window.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                analyzer.analyze(base, into: &bands)
            }
        }
        return bands
    }

    /// Consumer (PULL). Non-destructive peek of the most recent `count` samples
    /// of `channel` into `destination`, zero-filling the front when fewer samples
    /// have been written.
    ///
    /// The peek does not advance any read cursor, so this consumer and
    /// ``latestSpectrum()`` never steal samples from each other even though both
    /// read channel 0.
    ///
    /// **A channel's ring is not evidence that the channel exists.** Channel 1
    /// retains the last stereo source's samples for the whole of a following mono
    /// track, so a caller must establish the live channel count from the engine's
    /// connection format before deciding to read channel 1 at all. Requests for a
    /// channel this provider does not meter leave `destination` untouched.
    public func latestWindow(
        channel: Int,
        into destination: UnsafeMutableBufferPointer<Float>,
        count: Int
    ) {
        channelRing(for: channel)?.readLatest(into: destination, count: count)
    }

    private func channelRing(for channel: Int) -> SPSCRingBuffer? {
        switch channel {
        case 0: ring
        case 1: channel1Ring
        default: nil
        }
    }
}
