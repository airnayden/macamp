import Synchronization

/// Lock-free single-producer / single-consumer ring buffer of `Float` audio samples.
///
/// PRODUCER = the real-time audio tap thread. Its only actions are a `memcpy`
/// into a pre-allocated backing store and a single release-ordered atomic store
/// of the write cursor. No allocation, no locks, no ARC traffic, no logging —
/// this is the validation of MacAMP's AUDIO-THREAD INVARIANT inside the spike.
///
/// CONSUMER = the display / analysis thread. It acquires the published cursor and
/// copies the most-recent `count` samples. The visualizer always wants the freshest
/// window, so overwritten history is intentionally dropped (no FIFO back-pressure).
///
/// `capacity` must be a power of two so the wrap is a single mask.
final class SPSCRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let mask: Int

    /// Total number of samples ever written (monotonic). The producer is the only
    /// writer; it publishes with `.releasing` so the consumer's `.acquiring` load
    /// is guaranteed to see the preceding sample writes.
    private let head = Atomic<UInt64>(0)

    /// CONSUMER-side diagnostic: total samples ever written (a non-zero value proves
    /// the audio tap has fired). Acquire-ordered to pair with the producer's release.
    var samplesWritten: UInt64 { head.load(ordering: .acquiring) }

    init(capacity: Int = 1 << 14) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0,
                     "capacity must be a power of two")
        self.capacity = capacity
        self.mask = capacity - 1
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0)
        self.storage = buffer
    }

    deinit { storage.deallocate() }

    /// PRODUCER (audio thread): copy `count` samples then publish the new cursor.
    /// `memcpy` + one atomic store only — invariant-safe.
    func write(_ source: UnsafePointer<Float>, count: Int) {
        guard count > 0, let base = storage.baseAddress else { return }
        // Only the producer mutates `head`, so a relaxed load of its own value is fine.
        let current = head.load(ordering: .relaxed)
        let start = Int(current & UInt64(mask))
        let firstChunk = min(count, capacity - start)
        base.advanced(by: start).update(from: source, count: firstChunk)
        if firstChunk < count {
            base.update(from: source.advanced(by: firstChunk), count: count - firstChunk)
        }
        head.store(current &+ UInt64(count), ordering: .releasing)
    }

    /// CONSUMER (display thread): copy the latest `count` samples into `destination`.
    /// Returns `false` (and zero-fills) until at least `count` samples have been written.
    @discardableResult
    func readLatest(into destination: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        let total = head.load(ordering: .acquiring)
        guard let base = storage.baseAddress else { return false }
        guard total >= UInt64(count) else {
            destination.update(repeating: 0, count: count)
            return false
        }
        let end = Int(total & UInt64(mask))          // one past the most-recent sample
        let startPos = (end - count) & mask
        let firstChunk = min(count, capacity - startPos)
        destination.update(from: base.advanced(by: startPos), count: firstChunk)
        if firstChunk < count {
            destination.advanced(by: firstChunk).update(from: base, count: count - firstChunk)
        }
        return true
    }
}
