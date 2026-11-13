import Darwin

/// A bs2b-compatible stereo crossfeed kernel.
///
/// Each channel is split into a highboosted direct path and a lowpassed crossfeed
/// path; the crossfeed path is then mixed into the *opposite* channel. The one-pole
/// lowpass's phase lag supplies the inter-aural time difference, so there is no
/// delay line. Compensation gain (`1/(1 − G_h + G)`) is applied in the output stage
/// so the DC response stays unity.
///
/// ``process(left:right:frameCount:)`` runs on the render thread: it allocates
/// nothing, takes no lock, retains nothing, and logs nothing. All filter state
/// lives in stored `Double` properties, and new coefficients arrive through the
/// wait-free ``CrossfeedCoefficientBox``.
///
/// Reference behaviour is pinned by libbs2b 3.1.0's own impulse response — see
/// `tools/fixtures/bs2b/`.
public final class CrossfeedKernel: @unchecked Sendable {
    private let coefficientBox: CrossfeedCoefficientBox
    private var coefficients: CrossfeedCoefficients

    private var lowpassStateLeft: Double = 0
    private var lowpassStateRight: Double = 0
    private var highboostStateLeft: Double = 0
    private var highboostStateRight: Double = 0
    private var previousInputLeft: Double = 0
    private var previousInputRight: Double = 0

    public init(level: CrossfeedLevel = .default, sampleRate: Double = 44100) {
        let derived = CrossfeedCoefficients(level: level, sampleRate: sampleRate)
        coefficients = derived
        coefficientBox = CrossfeedCoefficientBox(coefficients: derived)
    }

    /// The box the main actor publishes parameter changes through.
    public var parameterBox: CrossfeedCoefficientBox {
        coefficientBox
    }

    /// The coefficients the render thread is currently filtering with.
    public var activeCoefficients: CrossfeedCoefficients {
        coefficients
    }

    /// Publishes `level` at `sampleRate` for the render thread to adopt on its
    /// next block. Safe to call from the main actor while audio is running.
    public func setLevel(_ level: CrossfeedLevel, sampleRate: Double) {
        coefficientBox.publish(CrossfeedCoefficients(level: level, sampleRate: sampleRate))
    }

    /// Clears all filter state. Call when playback stops or the graph is rebuilt,
    /// never mid-stream — discarding state mid-stream produces a transient.
    public func reset() {
        lowpassStateLeft = 0
        lowpassStateRight = 0
        highboostStateLeft = 0
        highboostStateRight = 0
        previousInputLeft = 0
        previousInputRight = 0
    }

    /// Render-thread path. Crossfeeds `frameCount` frames in place.
    ///
    /// Zero heap allocation, zero locks, zero ARC traffic.
    public func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        if let fresh = coefficientBox.latest() {
            coefficients = fresh
        }
        guard frameCount > 0 else { return }

        let lowpassB1 = coefficients.lowpassB1
        let lowpassA0 = coefficients.lowpassA0
        let highboostB1 = coefficients.highboostB1
        let highboostA0 = coefficients.highboostA0
        let highboostA1 = coefficients.highboostA1
        let outputGain = coefficients.outputGain

        for frame in 0 ..< frameCount {
            let inputLeft = Double(left[frame])
            let inputRight = Double(right[frame])

            lowpassStateLeft = lowpassA0 * inputLeft + lowpassB1 * lowpassStateLeft
            lowpassStateRight = lowpassA0 * inputRight + lowpassB1 * lowpassStateRight

            highboostStateLeft = highboostA0 * inputLeft
                + highboostA1 * previousInputLeft
                + highboostB1 * highboostStateLeft
            highboostStateRight = highboostA0 * inputRight
                + highboostA1 * previousInputRight
                + highboostB1 * highboostStateRight

            previousInputLeft = inputLeft
            previousInputRight = inputRight

            left[frame] = Float((highboostStateLeft + lowpassStateRight) * outputGain)
            right[frame] = Float((highboostStateRight + lowpassStateLeft) * outputGain)
        }
    }
}
