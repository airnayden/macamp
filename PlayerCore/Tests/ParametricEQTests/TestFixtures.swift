import Foundation

/// Locates the committed AutoEq fixtures next to this test target.
///
/// `Fixtures/` is excluded from the build (see Package.swift) and loaded by path
/// via `#filePath`, mirroring the Metadata / Decoding / Persistence fixture
/// pattern. See `Fixtures/README.md` for provenance.
enum TestFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// An unmodified AutoEq `ParametricEQ.txt` profile: preamp + 10 enabled
    /// filters covering `PK`, `LSC`, and `HSC`.
    static var sennheiserHD650: URL {
        url("Sennheiser HD 650 ParametricEQ.txt")
    }

    static func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
