import Darwin

/// A minimal lock-free monotonic counter backed by a 64-bit atomic add.
///
/// The backing storage is a class stored property, so its address is stable on
/// the heap and may be passed to `OSAtomicAdd64Barrier` safely.
final class AtomicCounter: @unchecked Sendable {
    private var value: Int64 = 0

    /// Atomically adds `amount` and returns the new value.
    @discardableResult
    func add(_ amount: Int) -> UInt64 {
        UInt64(bitPattern: OSAtomicAdd64Barrier(Int64(amount), &value))
    }

    /// Atomically loads the current value (add of zero with a full barrier).
    func load() -> UInt64 {
        UInt64(bitPattern: OSAtomicAdd64Barrier(0, &value))
    }
}
