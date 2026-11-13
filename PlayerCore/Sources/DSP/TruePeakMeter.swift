import Accelerate
import Foundation

/// One true-peak reading: the linear magnitude plus its dBTP rendering.
public struct TruePeakMeasurement: Sendable, Equatable, Hashable {
    /// Linear true-peak magnitude, `1.0` being digital full scale.
    ///
    /// Values above `1.0` are normal and are the whole point of the meter: a
    /// peak that falls between two samples can exceed every sample there is.
    public let linear: Float

    /// Clamps to a non-negative magnitude (`NaN` reads as silence).
    public init(linear: Float) {
        self.linear = max(0, linear)
    }

    /// `20·log10(linear)`, or `-.infinity` for digital silence.
    public var dBTP: Float {
        linear > 0 ? 20 * log10(linear) : -.infinity
    }

    /// The reading for digital silence — also what an empty block reports.
    public static let silence = TruePeakMeasurement(linear: 0)
}

/// An ITU-R BS.1770-4 Annex 2 true-peak meter.
///
/// Every input sample is interpolated to four through the Annex 2 polyphase
/// FIR (``TruePeakFilter``) and the largest magnitude across all four branches
/// is kept, so an inter-sample peak is measured rather than missed.
///
/// All scratch storage is allocated in `init` and `process` performs **no heap
/// allocation** — the meter is usable on a decode worker or a UI pull cadence
/// without adding allocator traffic. It is NOT safe on the render thread all
/// the same: the filter is roughly 48 multiplies per input sample per channel,
/// which belongs off the audio callback.
///
/// Per-channel delay lines carry across calls, so a file fed one block at a
/// time reads exactly as it would fed whole — there is no seam at a block
/// boundary. Both consumers work off the same two entry points:
///
/// - an offline scanner feeds every decoded block and reads ``measurement``
///   once the file is done;
/// - a live meter feeds the window it just pulled and uses `process`'s return
///   value as that window's own reading.
///
/// Not internally synchronised: confine one instance to one consumer.
public final class TruePeakMeter: @unchecked Sendable {
    /// Interpolation factor — four filtered outputs per input sample.
    public static let oversamplingFactor = TruePeakFilter.oversamplingFactor

    /// Longest run `process` filters in a single vDSP pass. Larger blocks are
    /// split into runs of this length, which is what keeps the scratch buffers
    /// a fixed size no matter how big a block a caller hands over.
    static let chunkCapacity = 1024

    /// Channels the meter tracks independently.
    public let channelCount: Int

    /// The four branches' taps, phase-major and each branch REVERSED, so one
    /// `vDSP_conv` correlation per branch evaluates ``TruePeakFilter``'s
    /// convolution.
    private let taps: UnsafeMutablePointer<Float>
    /// `TruePeakFilter.historyLength` carried samples, then the run to filter.
    private let input: UnsafeMutablePointer<Float>
    /// One branch's filtered output for the run currently in `input`.
    private let output: UnsafeMutablePointer<Float>
    /// Each channel's carried tail, `TruePeakFilter.historyLength` per channel.
    private let history: UnsafeMutablePointer<Float>
    /// Each channel's running peak since the last ``reset()``.
    private let peaks: UnsafeMutablePointer<Float>

    public init(channelCount: Int = 1) {
        precondition(channelCount > 0, "TruePeakMeter needs at least one channel")
        self.channelCount = channelCount

        let tapsPerPhase = TruePeakFilter.tapsPerPhase
        taps = .allocate(capacity: TruePeakFilter.oversamplingFactor * tapsPerPhase)
        for (phaseIndex, phase) in TruePeakFilter.phases.enumerated() {
            for (tapIndex, tap) in phase.reversed().enumerated() {
                taps[phaseIndex * tapsPerPhase + tapIndex] = tap
            }
        }

        input = .allocate(capacity: TruePeakFilter.historyLength + Self.chunkCapacity)
        input.initialize(repeating: 0, count: TruePeakFilter.historyLength + Self.chunkCapacity)
        output = .allocate(capacity: Self.chunkCapacity)
        output.initialize(repeating: 0, count: Self.chunkCapacity)
        history = .allocate(capacity: channelCount * TruePeakFilter.historyLength)
        history.initialize(repeating: 0, count: channelCount * TruePeakFilter.historyLength)
        peaks = .allocate(capacity: channelCount)
        peaks.initialize(repeating: 0, count: channelCount)
    }

    deinit {
        taps.deallocate()
        input.deallocate()
        output.deallocate()
        history.deallocate()
        peaks.deallocate()
    }

    // MARK: Measuring

    /// Filters one de-interleaved block of `channel` and returns THAT block's
    /// true peak; the channel's running peak is raised to match.
    ///
    /// An empty block is a no-op reading as ``TruePeakMeasurement/silence``
    /// (`-∞ dBTP`) — `samples` is never dereferenced in that case.
    @discardableResult
    public func process(
        _ samples: UnsafePointer<Float>,
        count: Int,
        channel: Int = 0
    ) -> TruePeakMeasurement {
        precondition(channel >= 0 && channel < channelCount, "channel \(channel) out of range")
        guard count > 0 else { return .silence }

        let historyLength = TruePeakFilter.historyLength
        let channelHistory = history + channel * historyLength
        var blockPeak: Float = 0
        var offset = 0
        while offset < count {
            let run = min(Self.chunkCapacity, count - offset)
            input.update(from: channelHistory, count: historyLength)
            (input + historyLength).update(from: samples + offset, count: run)
            blockPeak = max(blockPeak, oversampledPeak(runLength: run))
            // `input` holds `historyLength + run` samples, so its last
            // `historyLength` — the tail the next run reaches back over —
            // starts at `run`.
            channelHistory.update(from: input + run, count: historyLength)
            offset += run
        }
        peaks[channel] = max(peaks[channel], blockPeak)
        return TruePeakMeasurement(linear: blockPeak)
    }

    /// ``process(_:count:channel:)`` over a buffer pointer. An empty buffer
    /// reads as ``TruePeakMeasurement/silence``.
    @discardableResult
    public func process(
        _ samples: UnsafeBufferPointer<Float>,
        channel: Int = 0
    ) -> TruePeakMeasurement {
        guard let base = samples.baseAddress, !samples.isEmpty else { return .silence }
        return process(base, count: samples.count, channel: channel)
    }

    /// The largest true peak seen on ANY channel since the last ``reset()``.
    public var measurement: TruePeakMeasurement {
        var peak: Float = 0
        for channel in 0 ..< channelCount {
            peak = max(peak, peaks[channel])
        }
        return TruePeakMeasurement(linear: peak)
    }

    /// The largest true peak seen on one channel since the last ``reset()``.
    public func measurement(channel: Int) -> TruePeakMeasurement {
        precondition(channel >= 0 && channel < channelCount, "channel \(channel) out of range")
        return TruePeakMeasurement(linear: peaks[channel])
    }

    /// Clears the carried delay lines and every running peak — call this
    /// between tracks so one file's tail never colours the next one's reading.
    public func reset() {
        history.update(repeating: 0, count: channelCount * TruePeakFilter.historyLength)
        peaks.update(repeating: 0, count: channelCount)
    }

    // MARK: Private

    /// Largest magnitude across all four branches for the run in `input`.
    private func oversampledPeak(runLength: Int) -> Float {
        let tapsPerPhase = TruePeakFilter.tapsPerPhase
        var peak: Float = 0
        for phase in 0 ..< TruePeakFilter.oversamplingFactor {
            vDSP_conv(
                input,
                1,
                taps + phase * tapsPerPhase,
                1,
                output,
                1,
                vDSP_Length(runLength),
                vDSP_Length(tapsPerPhase)
            )
            var branchPeak: Float = 0
            vDSP_maxmgv(output, 1, &branchPeak, vDSP_Length(runLength))
            peak = max(peak, branchPeak)
        }
        return peak
    }
}
