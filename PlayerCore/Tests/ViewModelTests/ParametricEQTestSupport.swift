import AudioEngine
import Foundation
import Persistence
import Testing
@testable import ViewModels

// ParametricEQTestSupport — fixtures and the model factory for the parametric
// editor's three suites.
//
// Split out so each suite file stays inside SwiftLint's `file_length` budget, the
// same move `LoudnessScanTestSupport` made for `LoudnessScanViewModelTests`.
//
// Fixtures are located through `#filePath` into `ParametricEQTests/Fixtures`, the
// same walk-up `AudioEngineFixtures` uses: the committed AutoEq profile is read by
// BOTH suites rather than being duplicated, and `ViewModelTests` needs no
// `Package.swift` `exclude:` of its own.

// MARK: - Fixtures

enum ParametricFixtures {
    /// The verbatim upstream AutoEq profile committed for `ParametricEQTests`.
    static var autoEqProfile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("ParametricEQTests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Sennheiser HD 650 ParametricEQ.txt")
    }

    /// Writes `text` into a fresh temporary file and returns its URL.
    static func temporaryProfile(_ text: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macamp-parametric-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Profile.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// `count` distinct neutral bells — distinct so an order-preservation assertion
    /// is meaningful and a capacity refusal is not hiding a de-duplication.
    static func filters(count: Int) -> [ParametricFilter] {
        (0 ..< count).map {
            ParametricFilter(
                type: .peaking,
                frequency: 100 + Double($0) * 100,
                gainDB: 1,
                qFactor: 1
            )
        }
    }
}

@MainActor
func makeModel(
    presets: [ParametricEQPreset] = []
) -> (ParametricEQViewModel, FakePlaybackEngine) {
    let engine = FakePlaybackEngine()
    let store = FakeParametricEQPresetStore(presets: presets)
    return (ParametricEQViewModel(engine: engine, presetStore: store), engine)
}
