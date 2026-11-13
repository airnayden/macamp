// AssistantUITestSeam — the launch-environment fakes the assistant XCUITests drive.
//
// Compiled out of Release entirely, and inert unless the hermetic
// `AppEnvironment.liveForUITesting()` seam is already active (`UITEST_SEED_PATH`),
// so shipping behaviour is untouched by construction rather than by a flag check.
//
// TWO FAKES, FOR TWO THINGS THAT CANNOT BE DRIVEN FROM THE UI:
//
//   * ``fakeParser`` — the fixture library carries no genre and no year, so the real
//     heuristic tier resolves "upbeat 90s rock" to `year BETWEEN 1990 AND 1999` and
//     correctly matches nothing. An unconstrained spec is the smallest fake that
//     leaves the WHOLE production path (rule variants → read-only id preview → mix
//     generator → naming → proposal) under test while still selecting the fixtures.
//
//   * ``stagedProposal(profileId:)`` — `submit` only ever produces
//     `.createPlaylist`, so a tag change-set and a rename that cannot resolve are
//     unreachable from the pane. Staging them through the same button keeps the test
//     driving the real preview sheet, the real confirmation gate and the real
//     `AssistantViewModel.apply`.
//
// The failing rename is a REAL repository failure, not a stubbed throw: the playlist
// id does not exist, so `applyRename`'s `fetchPlaylist` returns `nil` and the
// production code raises ``AssistantProposalError/playlistNotFound(id:)`` — the same
// path a playlist deleted in another window would take.
#if DEBUG
    import Foundation
    import Metadata
    import Services
    import ViewModels

    enum AssistantUITestSeam {
        /// A playlist id no fixture database can hold, so `fetchPlaylist` misses.
        static let missingPlaylistID: Int64 = 9_876_543

        static var fakeParser: (any NaturalLanguageQueryParsing)? {
            guard isActive, value(for: "UITEST_ASSISTANT_FAKE") == "1" else { return nil }
            return UnconstrainedQueryParser()
        }

        /// The proposal the Suggest button should file instead of parsing the request,
        /// or `nil` when the test wants the real submit path.
        static func stagedProposal(profileId: Int64) -> AIProposal? {
            guard isActive, let kind = value(for: "UITEST_ASSISTANT_PROPOSAL") else { return nil }
            switch kind {
            case "tagChangeSet":
                return AIProposal(profileId: profileId, kind: .tagChangeSet(patches: tagPatches()))
            case "failingRename":
                return AIProposal(
                    profileId: profileId,
                    kind: .rename(playlistId: missingPlaylistID, name: "Renamed By Assistant")
                )
            default:
                return nil
            }
        }

        private static var isActive: Bool {
            value(for: "UITEST_SEED_PATH") != nil
        }

        private static func value(for key: String) -> String? {
            ProcessInfo.processInfo.environment[key]
        }

        /// Patches the two seeded fixture files. Track ids match the insertion order
        /// `AppEnvironment.seedFixtureTracks` writes them in.
        private static func tagPatches() -> [TagPatch] {
            guard let seedPath = value(for: "UITEST_SEED_PATH") else { return [] }
            let folder = URL(fileURLWithPath: seedPath, isDirectory: true)
            return [
                TagPatch(
                    trackId: 1,
                    fileURL: folder.appendingPathComponent("Aurora Anthem.mp3"),
                    patch: WritableMetadata(genre: "Shoegaze", year: 1994)
                ),
                TagPatch(
                    trackId: 2,
                    fileURL: folder.appendingPathComponent("Zephyr Waltz.mp3"),
                    patch: WritableMetadata(albumArtist: "Fixture Artist", genre: "Shoegaze")
                ),
            ]
        }
    }

    /// Resolves every request to "no constraint at all", which ``PlaylistQuerySpec``
    /// documents as widening to the whole visible library rather than emptying it.
    private struct UnconstrainedQueryParser: NaturalLanguageQueryParsing {
        func parse(text _: String, locale _: Locale) async throws -> PlaylistQuerySpec {
            PlaylistQuerySpec()
        }
    }
#endif
