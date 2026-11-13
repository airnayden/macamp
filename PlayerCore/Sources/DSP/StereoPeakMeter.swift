// StereoPeakMeter — the CONSUMER half of the stereo metering path.
//
// The tap's only job is two memcpys into two rings. Everything that costs real
// arithmetic — the BS.1770-4 polyphase interpolation, the clip decision, the
// mono fallback — happens here, on whatever cadence the UI pulls at. The audio
// thread never calls into this file and never learns it exists.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// One pull's stereo true-peak reading.
public struct StereoPeakReading: Sendable, Equatable {
    /// Channel 0's true peak over the window just pulled.
    public let left: TruePeakMeasurement

    /// Channel 1's true peak, or ``left`` mirrored when ``isMono``.
    public let right: TruePeakMeasurement

    /// `true` when the live source carries fewer than two channels, so ``right``
    /// is a mirror of ``left`` rather than a measurement of its own.
    public let isMono: Bool

    public init(left: TruePeakMeasurement, right: TruePeakMeasurement, isMono: Bool) {
        self.left = left
        self.right = right
        self.isMono = isMono
    }

    /// The louder of the two channels — what a single clip light reflects.
    public var loudest: TruePeakMeasurement {
        left.linear >= right.linear ? left : right
    }

    /// `true` once either channel exceeds ``StereoPeakMeter/clipThresholdDBTP``.
    ///
    /// Digital silence reads `-.infinity dBTP`, which is below every threshold,
    /// so an idle graph never lights the indicator.
    public var isClipping: Bool {
        loudest.dBTP > StereoPeakMeter.clipThresholdDBTP
    }

    /// Both channels silent, treated as stereo.
    public static let silence = StereoPeakReading(left: .silence, right: .silence, isMono: false)
}

/// Pulls the latest window of each metered channel out of a ``SpectrumProvider``
/// and measures its true peak.
///
/// Consumer-side by construction: the meter is roughly 48 multiplies per input
/// sample per channel (see ``TruePeakMeter``), which belongs on a display-link
/// tick and nowhere near the render callback.
///
/// Not internally synchronised — confine one instance to one consumer, the same
/// rule ``TruePeakMeter`` carries.
public final class StereoPeakMeter: @unchecked Sendable {
    /// dBTP above which the clip indicator lights.
    ///
    /// `-0.3` rather than `0` because an inter-sample peak this close to full
    /// scale will clip a downstream converter or lossy encoder even though no
    /// individual sample did.
    public static let clipThresholdDBTP: Float = -0.3

    /// Samples pulled per channel per read.
    ///
    /// One tap buffer's worth, which comfortably covers a 60 Hz pull interval
    /// (735 samples at 44.1 kHz) so no transient falls between two reads. The
    /// peek is non-destructive, so consecutive pulls overlap slightly; that costs
    /// a peak being reported for one extra frame and never misses one.
    public static let defaultWindowFrameCount = 1024

    /// Samples this meter pulls per channel on every ``read(from:channelCount:)``.
    public let windowFrameCount: Int

    /// The most recent reading, so a view can re-render without re-pulling.
    public private(set) var reading: StereoPeakReading = .silence

    private let meter = TruePeakMeter(channelCount: SpectrumProvider.meteredChannelCount)
    private var window: [Float]
    private var lastChannelCount: Int?

    public init(windowFrameCount: Int = StereoPeakMeter.defaultWindowFrameCount) {
        precondition(windowFrameCount > 0, "StereoPeakMeter needs a non-empty window")
        self.windowFrameCount = windowFrameCount
        window = [Float](repeating: 0, count: windowFrameCount)
    }

    /// Pulls one window per live channel and returns their true peaks.
    ///
    /// `channelCount` is the LIVE channel count, read by the caller from
    /// `PlaybackEngine.currentConnectionFormat` on this same pull. It is the only
    /// mono signal in the system: the producer publishes nothing, and channel 1's
    /// ring keeps the last stereo source's samples for the whole of a following
    /// mono track. Reading that ring on the strength of its contents alone would
    /// replay those samples and latch a clip light the live source cannot
    /// produce, so below two channels this mirrors ``StereoPeakReading/left``
    /// instead and never touches channel 1.
    ///
    /// A change in `channelCount` resets the interpolator: a new stream's first
    /// window must not be filtered against the previous one's tail. Within one
    /// format the delay lines deliberately carry across reads — that continuity is
    /// what keeps the reading seamless at a window boundary, so there is no
    /// per-pull reset.
    @discardableResult
    public func read(from provider: SpectrumProvider, channelCount: Int) -> StereoPeakReading {
        if lastChannelCount != channelCount {
            lastChannelCount = channelCount
            meter.reset()
        }
        let isMono = channelCount < SpectrumProvider.meteredChannelCount
        let left = measure(provider, channel: 0)
        let right = isMono ? left : measure(provider, channel: 1)
        let result = StereoPeakReading(left: left, right: right, isMono: isMono)
        reading = result
        return result
    }

    /// Clears the carried delay lines and the published reading — for a stop or a
    /// graph rebuild, never mid-stream.
    public func reset() {
        meter.reset()
        lastChannelCount = nil
        reading = .silence
    }

    private func measure(_ provider: SpectrumProvider, channel: Int) -> TruePeakMeasurement {
        window.withUnsafeMutableBufferPointer { buffer in
            provider.latestWindow(channel: channel, into: buffer, count: windowFrameCount)
            guard let base = buffer.baseAddress else { return .silence }
            return meter.process(base, count: windowFrameCount, channel: channel)
        }
    }
}
