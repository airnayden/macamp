import Foundation

/// Resolves a path under `LyricsTests/Fixtures/` via `#filePath` (the same
/// committed-fixture pattern used by Persistence/Metadata tests). `Fixtures` is
/// `exclude`d from the target, so fixtures are read from the source tree, never
/// a bundle.
func lyricsFixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name)
}

/// Tolerant time comparison: `.lrc` fractions like `16.20` are not exactly
/// representable in binary, so direct `==` on seconds is unsafe.
func approxEqual(_ lhs: TimeInterval, _ rhs: TimeInterval, tolerance: TimeInterval = 0.0005) -> Bool {
    abs(lhs - rhs) < tolerance
}
