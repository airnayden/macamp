import Foundation

/// Locates the committed decode fixtures shared with the Decoding suite.
///
/// `Fixtures/` is excluded from the build (see Package.swift) and loaded by path
/// via `#filePath`, so both suites read the SAME binaries rather than committing
/// a second copy of the same tone.
enum AudioEngineFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("DecodingTests/Fixtures", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static var flac: URL {
        url("tone.flac")
    }

    static var corruptFlac: URL {
        url("corrupt.flac")
    }

    /// DSD64 — the one DSD rate SFB decimates to PCM.
    static var dsf: URL {
        url("tone.dsf")
    }

    /// DSD128 — refused rather than resampled.
    static var dsd128: URL {
        url("tone-dsd128.dsf")
    }
}
