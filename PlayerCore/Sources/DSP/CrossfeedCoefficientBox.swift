import Darwin

/// Exclusive hand-off of ``CrossfeedCoefficients`` from a non-real-time
/// publisher to the render thread. Payload copies never overlap with writes.
///
/// The render thread makes one atomic ownership attempt and keeps its previous
/// coefficients on contention. Only the publisher may wait. Both paths perform
/// zero heap allocation after initialization.
public final class CrossfeedCoefficientBox: @unchecked Sendable {
    private let access = AtomicAccessGate()
    private var coefficients: CrossfeedCoefficients
    private let generation = AtomicCounter()

    public init(coefficients: CrossfeedCoefficients) {
        self.coefficients = coefficients
    }

    // MARK: Producer

    /// Publishes coefficients for a future render block. May wait for a reader;
    /// must not run on the audio thread. Zero heap allocation.
    public func publish(_ coefficients: CrossfeedCoefficients) {
        access.acquire()
        defer { access.release() }
        self.coefficients = coefficients
        generation.add(1)
    }

    // MARK: Consumer

    /// Render-thread path. Returns the current coefficients, or `nil` when the
    /// publisher owns the payload. One ownership attempt, no waiting or allocation.
    public func latest() -> CrossfeedCoefficients? {
        guard access.tryAcquire() else { return nil }
        defer { access.release() }
        return coefficients
    }

    // MARK: Introspection

    /// The number of completed publications.
    public var publishCount: UInt64 {
        generation.load()
    }
}
