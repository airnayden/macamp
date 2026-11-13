import Darwin

/// Exclusive ownership of non-atomic payload storage. Real-time callers attempt
/// acquisition once; only non-real-time callers may wait.
final class AtomicAccessGate: @unchecked Sendable {
    private let state: UnsafeMutablePointer<Int32>

    init() {
        state = .allocate(capacity: 1)
        state.initialize(to: 0)
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
    }

    func tryAcquire() -> Bool {
        OSAtomicCompareAndSwap32Barrier(0, 1, state)
    }

    func acquire() {
        while !tryAcquire() {
            sched_yield()
        }
    }

    func release() {
        let released = OSAtomicCompareAndSwap32Barrier(1, 0, state)
        assert(released, "access gate released without ownership")
    }
}
