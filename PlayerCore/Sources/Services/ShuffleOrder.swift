// ShuffleOrder — a STABLE shuffled play order plus a deterministic generator.
//
// "Stable" is the whole point: the order is precomputed ONCE when shuffle is
// engaged and then never re-randomised mid-cycle, so pressing next/previous walks
// a fixed permutation instead of re-rolling on every step (which would replay or
// skip tracks unpredictably). The current track can be pinned to the front so
// playback continues from where it is when shuffle is toggled on.
//
// The shuffle is a textbook Fisher–Yates over an injected `RandomNumberGenerator`;
// tests inject ``SeededRandomNumberGenerator`` for byte-stable, reproducible
// orders, while production uses the system generator.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Builders for a stable shuffled play order over a list of ``TrackRef/id``s.
public enum ShuffleOrder {
    /// Returns a Fisher–Yates permutation of `ids`, optionally pinning one id to
    /// the front (so the currently-playing track stays current).
    ///
    /// - Parameters:
    ///   - ids: The ids to permute.
    ///   - pinnedFirst: An id to move to index 0 after shuffling, if present.
    ///   - generator: The randomness source, advanced in place.
    public static func make(
        _ ids: [UUID],
        pinnedFirst: UUID?,
        using generator: inout any RandomNumberGenerator
    ) -> [UUID] {
        var result = ids
        var upper = result.count - 1
        while upper > 0 {
            let pick = Int(generator.next(upperBound: UInt(upper + 1)))
            result.swapAt(upper, pick)
            upper -= 1
        }
        if let pinned = pinnedFirst, let position = result.firstIndex(of: pinned) {
            result.swapAt(0, position)
        }
        return result
    }
}

/// A deterministic `RandomNumberGenerator` (SplitMix64) for reproducible shuffles.
///
/// Seeded once, it produces the same stream every run — so a shuffle-order test
/// asserts on an exact permutation instead of a statistical property.
public struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// Creates a generator seeded with `seed`.
    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
