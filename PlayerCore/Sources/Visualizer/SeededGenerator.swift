import Foundation

/// Deterministic `RandomNumberGenerator` (SplitMix64).
///
/// The visualizer seeds *all* pseudo-random behaviour (particle layout, art
/// mode) through this generator so that a given `(seed, mode, spectrum)` tuple
/// renders reproducibly. Reproducibility is what makes golden-image testing of
/// the GPU output possible.
///
/// SplitMix64 is a tiny, statistically solid 64-bit generator with no external
/// state — perfect for embedding in a value type that is copied per frame.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator seeded with `seed`. Equal seeds yield identical
    /// sequences across processes and platforms.
    init(seed: UInt64) {
        state = seed
    }

    /// Returns the next 64-bit value and advances the internal state.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var word = state
        word = (word ^ (word >> 30)) &* 0xBF58_476D_1CE4_E5B9
        word = (word ^ (word >> 27)) &* 0x94D0_49BB_1331_11EB
        return word ^ (word >> 31)
    }
}
