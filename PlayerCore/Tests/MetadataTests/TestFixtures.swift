import Foundation

/// Locates the committed binary fixtures next to this test target.
///
/// `Fixtures/` is excluded from the build (see Package.swift) and loaded by path
/// via `#filePath`, mirroring the Decoding / Persistence fixture pattern. See
/// `Fixtures/README.md` for how each file was generated.
enum TestFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// 16-bit FLAC carrying full tags + an embedded front cover + ReplayGain.
    static var flac: URL {
        url("full.flac")
    }

    /// MP3 carrying ID3v2 tags + an embedded APIC cover + ReplayGain TXXX frames.
    static var mp3: URL {
        url("full.mp3")
    }

    /// AAC-in-MP4 carrying tags + an embedded cover atom.
    static var m4a: URL {
        url("full.m4a")
    }

    /// Valid `fLaC` magic followed by garbage — a parser-claims-then-rejects file.
    static var corruptFlac: URL {
        url("corrupt.flac")
    }
}
