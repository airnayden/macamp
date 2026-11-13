// UITestFixtureOptions — every fixture switch the hermetic UI-test seed reads, as
// ONE value.
//
// The seed used to grow one `Bool` parameter per scenario, and when
// `makeUITestDatabase` approached SwiftLint's `function_parameter_count` ceiling the
// third switch dodged it by reading its own launch-environment key from inside its
// own `seedIfRequested`. That works exactly once: with the keys scattered across the
// fixtures there is no single place that says what the seed can be asked for, and
// each new self-gated fixture is invisible to the composition root that is supposed
// to own it.
//
// So a fourth switch bundles all of them instead — the move recorded in
// `.omo/notepads/ai-fixes-round2/issues.md` as the right answer if a fourth ever
// appeared. Every key is now read in ONE function, every fixture takes an explicit
// argument, and `makeUITestDatabase` is back to two parameters permanently.
import Foundation

#if DEBUG
    /// Which optional fixtures the UI-test database is seeded with.
    struct UITestFixtureOptions: Equatable {
        /// Reuse an existing database file instead of rebuilding it — the
        /// relaunch-and-assert-persistence scenarios.
        var preserveExisting = false
        /// Per-profile lifetime counters with deliberately NO `playEvent` rows.
        var lifetimePlayCounts = false
        /// The widened library the contextual-action suites drive
        /// (``AIContextualFixture``).
        var contextualActions = false
        /// The duplicate / genre-spelling shapes the library-health suite needs
        /// (``HygieneFixture``).
        var hygiene = false
        /// A registered library root with a nested subfolder, so the sidebar's Folders
        /// section has a tree to expand (``FolderTreeUITestFixture``).
        var folderTree = false
        /// Current `trackAudioFeature` rows for every present track, in the shape
        /// asked for — or `nil` for an unanalysed library
        /// (``AudioFeatureFixture``).
        var audioFeatures: AudioFeatureFixture.Shape?
        /// A directory of REAL audio files to insert one present row per, or `nil`
        /// for the zero-byte placeholders every other fixture uses
        /// (``RealAudioLibraryFixture``).
        var realAudioDirectory: String?
        /// One genre to stamp on every real-audio row, or `nil` to leave them
        /// untagged. Read beside the directory because it qualifies that fixture and
        /// nothing else (``RealAudioLibraryFixture``).
        var realAudioGenre: String?

        static func fromLaunchEnvironment(_ environment: [String: String]) -> UITestFixtureOptions {
            UITestFixtureOptions(
                preserveExisting: environment["UITEST_PRESERVE_DATABASE"] == "1",
                lifetimePlayCounts: environment["UITEST_SEED_PLAY_COUNTS"] == "1",
                contextualActions: environment[AIContextualFixture.environmentKey] == "1",
                hygiene: environment[HygieneFixture.environmentKey] == "1",
                folderTree: environment[FolderTreeUITestFixture.environmentKey] == "1",
                audioFeatures: environment[AudioFeatureFixture.environmentKey]
                    .flatMap(AudioFeatureFixture.Shape.init(rawValue:)),
                realAudioDirectory: environment[RealAudioLibraryFixture.environmentKey],
                realAudioGenre: environment[RealAudioLibraryFixture.genreEnvironmentKey]
            )
        }
    }
#endif
