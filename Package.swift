// swift-tools-version: 6.0
// PlayerCore — the platform-agnostic shared core for MacAMP (display name "MacAMP").
//
// Swift 6 language mode (complete strict concurrency) is implied by tools-version 6.0.
// PlayerCore MUST NOT import AppKit or UIKit — it is shared verbatim between the
// macOS, iOS and Widget shells. A CI portability guard enforces this invariant.
//
// swiftlint:disable file_length
// A declarative manifest is a target list, not a unit of logic, and cannot be split into
// extensions the way `AppDatabase+Migrations.swift` was. Scoped to this ONE rule on purpose:
// an `excluded:` entry in `.swiftlint.yml` would also silence `force_unwrapping` here.
import PackageDescription

let package = Package(
    name: "PlayerCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .library(name: "Decoding", targets: ["Decoding"]),
        .library(name: "DSP", targets: ["DSP"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Metadata", targets: ["Metadata"]),
        .library(name: "Artwork", targets: ["Artwork"]),
        .library(name: "Lyrics", targets: ["Lyrics"]),
        .library(name: "MIDI", targets: ["MIDI"]),
        .library(name: "Visualizer", targets: ["Visualizer"]),
        .library(name: "Services", targets: ["Services"]),
        .library(name: "ViewModels", targets: ["ViewModels"]),
        .library(name: "Models", targets: ["Models"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        // Karaoke stem separation. A PRODUCT (not just a target) so Tuist's `.external(name:)` resolves it (todo 17).
        .library(name: "Separation", targets: ["Separation"]),
        // Test/QA support (offline render harness, signal generators, analysis). Exposed
        // as a library product so the macamp-cli executable target — and Tuist's package
        // graph resolution for the apps — can locate it (it lives outside Tests/).
        .library(name: "PlayerCoreTestSupport", targets: ["PlayerCoreTestSupport"]),
        .executable(name: "macamp-cli", targets: ["macamp-cli"]),
    ],
    dependencies: [
        // SQLite library / playlists. Pinned EXACT to the version whose API the
        // Persistence layer was written and verified against (matches the lockfile
        // resolved in Task 1). Compatible with Tuist/Package.swift's `from: "7.0.0"`.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        // Universal audio decoders + TagLib metadata. Pinned EXACT (0.12.1); the Phase 0
        // ADR (Spikes/ADR-audio-engine.md) verified Option A on this exact version.
        // Consumed by Decoding (Task 8), Metadata (Task 11), AudioEngine (Task 9).
        .package(url: "https://github.com/sbooth/SFBAudioEngine", exact: "0.12.1"),
    ],
    targets: [
        .target(
            name: "AudioEngine",
            dependencies: [
                "Models",
                "Decoding",
                "DSP",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ],
            path: "PlayerCore/Sources/AudioEngine"
        ),
        .target(
            name: "Decoding",
            dependencies: [
                "Models",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ],
            path: "PlayerCore/Sources/Decoding"
        ),
        .target(
            name: "DSP",
            dependencies: ["Models"],
            path: "PlayerCore/Sources/DSP"
        ),
        .target(
            name: "Persistence",
            dependencies: [
                "Models",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Sources/Persistence"
        ),
        .target(
            name: "Metadata",
            dependencies: [
                "Models",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ],
            path: "PlayerCore/Sources/Metadata"
        ),
        .target(
            name: "Artwork",
            dependencies: ["Models", "Metadata"],
            path: "PlayerCore/Sources/Artwork"
        ),
        .target(
            name: "Lyrics",
            dependencies: ["Models", "Metadata", "Persistence", .product(name: "GRDB", package: "GRDB.swift")],
            path: "PlayerCore/Sources/Lyrics"
        ),
        .target(
            name: "MIDI",
            dependencies: ["Models", "AudioEngine"],
            path: "PlayerCore/Sources/MIDI"
        ),
        .target(
            name: "Visualizer",
            dependencies: ["Models", "DSP"],
            path: "PlayerCore/Sources/Visualizer"
        ),
        .target(
            name: "Services",
            dependencies: [
                "Models",
                "Persistence",
                "Metadata",
                "AudioEngine",
                "Lyrics",
                // Karaoke pre-warm service consumes the Separation seams (StemSeparating,
                // InstrumentalCaching, SeparationCacheKey). No cycle: Separation → Models/Decoding only.
                "Separation",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Sources/Services"
        ),
        .target(
            name: "ViewModels",
            dependencies: [
                "Models",
                "Services",
                "Persistence",
                "Metadata",
                "AudioEngine",
                "Visualizer",
                "Lyrics",
                "Artwork",
                "DesignSystem",
                // Karaoke button state derives from SeparationAvailability +
                // KaraokePrewarmProgress (PlayerViewModel karaoke surface, todo 14).
                "Separation",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Sources/ViewModels"
        ),
        .target(name: "Models", path: "PlayerCore/Sources/Models"),
        // Shared SwiftUI design layer + album-art theming. SwiftUI + CoreGraphics/
        // ImageIO/CryptoKit only (portability guard forbids AppKit/UIKit here).
        .target(name: "DesignSystem", path: "PlayerCore/Sources/DesignSystem"),
        // On-device stem separation (karaoke mode). Foundation/Accelerate/CoreML/
        // AVFAudio (system frameworks, imported in-source) + Decoding + Models. No
        // AppKit/UIKit (portability guard). Declared as a library product above so
        // Tuist's `.external(name:)` can resolve it into the macOS app.
        .target(
            name: "Separation",
            dependencies: ["Models", "Decoding"],
            path: "PlayerCore/Sources/Separation"
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: [
                "Persistence",
                "Models", // `tracksDirectlyIn(…, sort:)` takes a `Models.FolderFilesSort` the suites must name.
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/PersistenceTests",
            // Fixtures are loaded via #filePath, not Bundle.module — not a build input.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"],
            path: "PlayerCore/Tests/DesignSystemTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "DecodingTests",
            dependencies: ["Decoding", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/DecodingTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "DSPTests",
            dependencies: ["AudioEngine", "DSP", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/DSPTests"
        ),
        .testTarget(
            name: "AudioEngineTests",
            dependencies: ["AudioEngine", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/AudioEngineTests"
        ),
        .testTarget(
            name: "MetadataTests",
            dependencies: ["Metadata", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/MetadataTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "LibraryTests",
            dependencies: [
                "Persistence",
                "PlayerCoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/LibraryTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ScannerTests",
            dependencies: ["Services", "PlayerCoreTestSupport", .product(name: "GRDB", package: "GRDB.swift")],
            path: "PlayerCore/Tests/ScannerTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "CueTests",
            dependencies: ["Services"],
            path: "PlayerCore/Tests/CueTests",
            // `.cue` fixtures are loaded via #filePath, not Bundle.module — not a build input.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "AvailabilityTests",
            dependencies: ["Persistence", "PlayerCoreTestSupport", .product(name: "GRDB", package: "GRDB.swift")],
            path: "PlayerCore/Tests/AvailabilityTests"
        ),
        // The macOS watch service (FSEvents) is not linkable here, so this target
        // covers the Persistence contract it drives: a folder scan imports rows, and
        // removing a root reconciles availability without deleting any.
        .testTarget(
            name: "LibraryWatchTests",
            dependencies: ["Persistence", .product(name: "GRDB", package: "GRDB.swift")],
            path: "PlayerCore/Tests/LibraryWatchTests"
        ),
        .testTarget(
            name: "CoordinatorTests",
            dependencies: [
                "Services",
                "Separation",
                "PlayerCoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/CoordinatorTests"
        ),
        .testTarget(
            name: "ProfileTests",
            dependencies: ["Services", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/ProfileTests"
        ),
        .testTarget(
            name: "ArtworkTests",
            dependencies: ["Artwork", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/ArtworkTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ReplayGainTests",
            dependencies: ["Services", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/ReplayGainTests"
        ),
        // BS.1770-4 K-weighting + gated loudness. Split out of ReplayGainTests: the
        // tone fixtures run minutes of audio through the filter cascade, which is a
        // very different cost profile from the pure tag math next door.
        .testTarget(
            name: "LoudnessTests",
            dependencies: ["Services", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/LoudnessTests"
        ),
        .testTarget(
            name: "EnrichmentTests",
            dependencies: [
                "Services",
                "ViewModels",
                "Lyrics",
                "Metadata",
                "PlayerCoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/EnrichmentTests"
        ),
        .testTarget(
            name: "EQPresetTests",
            dependencies: ["Persistence", "PlayerCoreTestSupport", .product(name: "GRDB", package: "GRDB.swift")],
            path: "PlayerCore/Tests/EQPresetTests"
        ),
        // Parametric EQ mode — a SECOND mode beside the ten-band graphic EQ that
        // `EQPresetTests` covers. Kept as its own target so the two contracts can
        // never be confused for one another.
        .testTarget(
            name: "ParametricEQTests",
            dependencies: ["AudioEngine"],
            path: "PlayerCore/Tests/ParametricEQTests",
            exclude: ["Fixtures"]
        ),
        // Output-device seam. Covers `OutputDeviceControlling` against
        // `FakeOutputDeviceController` ONLY — the CoreAudio conformer lives in the
        // macOS shell (`macOS/Sources/Output/`) and is covered by `macampMacTests`,
        // because linking a HAL here would defeat the portability the seam exists for.
        .testTarget(
            name: "OutputDeviceTests",
            dependencies: ["Services", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/OutputDeviceTests"
        ),
        // File-integrity verification (FLAC stream MD5 + fake-lossless spectral
        // detector). Depends on `SFBAudioEngine` directly because the known-good
        // MD5 fixtures are ENCODED IN-TEST from deterministic signals rather than
        // committed — a checked-in binary could not prove the digest path without
        // also being trusted, and regenerating it would need an external tool.
        // The spectral detector's two fixtures ARE committed, for the opposite
        // reason: they need a real lossy encoder round trip, which no in-test
        // encode can stand in for. `exclude:` keeps both kinds out of the build.
        // See `Tests/IntegrityTests/Fixtures/README.md`.
        .testTarget(
            name: "IntegrityTests",
            dependencies: [
                "Decoding",
                "DSP",
                "Services",
                "PlayerCoreTestSupport",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine"),
            ],
            path: "PlayerCore/Tests/IntegrityTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "VisualizerTests",
            dependencies: ["Visualizer", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/VisualizerTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "MIDITests",
            dependencies: ["MIDI", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/MIDITests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "LyricsTests",
            dependencies: [
                "Lyrics",
                // The offline sweep lives in `Services` and pages the `Persistence` anti-join.
                "Services",
                "Persistence",
                "PlayerCoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/LyricsTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "NowPlayingTests",
            dependencies: ["Services", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/NowPlayingTests"
        ),
        .testTarget(
            name: "PlaylistIOTests",
            dependencies: ["Persistence", "PlayerCoreTestSupport", .product(name: "GRDB", package: "GRDB.swift")],
            path: "PlayerCore/Tests/PlaylistIOTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ViewModelTests",
            dependencies: [
                "ViewModels",
                "Separation",
                "PlayerCoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/ViewModelTests"
        ),
        .target(
            name: "PlayerCoreTestSupport",
            // `Services` (re-linking `Persistence`) backs `FakeProfileService`, `Separation` the karaoke fakes;
            // no cycle either way — no source target depends on PlayerCoreTestSupport.
            dependencies: ["Metadata", "Services", "Separation"],
            path: "PlayerCore/TestSupport/PlayerCoreTestSupport"
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/HarnessTests"
        ),
        .testTarget(
            name: "SeparationTests",
            dependencies: ["Separation", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/SeparationTests"
        ),
        .testTarget(
            name: "KaraokeTests",
            dependencies: ["Services", "Separation", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/KaraokeTests"
        ),
        // YouTube downloader contracts: URL normalization, queue/format/error models,
        // and the tool-process / release-fetch seams driven through their Fakes. No
        // GRDB — nothing in the downloads surface is persisted (in-memory queue only).
        .testTarget(
            name: "DownloadsTests",
            dependencies: ["Services", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/DownloadsTests"
        ),
        // The four targets below are local-ai-playlists scaffolds, declared up front
        // so the feature todos can land test files WITHOUT reopening this manifest.
        // Each holds only a placeholder suite today; the deps are the minimum that
        // compiles one. Widen a list in place rather than adding a target.
        // Listening insights (sessionizer, similarity, rediscovery, daypart, mixes).
        .testTarget(
            name: "InsightTests",
            dependencies: [
                "Services",
                "Persistence",
                "PlayerCoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/InsightTests"
        ),
        // Smart-playlist rules schema + compiler + evaluator over `smartPlaylist.rulesJson`.
        .testTarget(
            name: "SmartPlaylistTests",
            dependencies: [
                "Persistence",
                "PlayerCoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/SmartPlaylistTests"
        ),
        // vDSP feature extractor + analysis service. No GRDB — pure Accelerate math.
        .testTarget(
            name: "AudioFeatureTests",
            dependencies: ["Services", "PlayerCoreTestSupport"],
            path: "PlayerCore/Tests/AudioFeatureTests"
        ),
        // FoundationModels assistant: the Services orchestration seam + its ViewModels
        // surface, plus `LibraryToolbox` — the typed tool layer the FM / connector / MCP
        // adapters are all built on. `Persistence` + GRDB were added (rather than a new
        // target) so the toolbox suites can drive the real repositories over a seeded
        // in-memory database, per this manifest's "widen a list in place" note above.
        .testTarget(
            name: "AssistantTests",
            dependencies: [
                "Services",
                "ViewModels",
                "Persistence",
                "PlayerCoreTestSupport",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "PlayerCore/Tests/AssistantTests"
        ),
        .executableTarget(
            name: "macamp-cli",
            dependencies: [
                "PlayerCoreTestSupport",
                "Decoding",
                "Metadata",
                "Persistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/macamp-cli"
        ),
    ]
)
