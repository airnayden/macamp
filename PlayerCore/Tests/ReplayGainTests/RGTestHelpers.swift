// Shared assertion helpers for the ReplayGain suite.
import Foundation

/// Floating-point closeness used across the ReplayGain tests. The default
/// tolerance comfortably absorbs the `Double -> Float -> Double` round-trip the
/// engine boundary introduces while still separating values that differ by the
/// integer/dB amounts these tests assert.
func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-4) -> Bool {
    abs(lhs - rhs) <= tolerance
}
