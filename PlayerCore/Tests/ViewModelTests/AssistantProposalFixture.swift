import Foundation
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
@testable import ViewModels

/// Wires an ``AssistantViewModel`` over nothing but fakes, and keeps a handle on
/// each one so a test can assert what the view model actually asked for.
///
/// Every seam is recording rather than canned: the whole point of todo 17's
/// acceptance is "which rows, in which order, and how many times", which a fake
/// that only returns values cannot answer.
@MainActor
struct AssistantHarness {
    let store = ProposalStore()
    let playlists = FakePlaylistRepository()
    let smartPlaylists = FakeSmartPlaylistRepository()
    let mixGenerator = FakeMixGeneratorService()
    let writer = FakeMetadataWriter()
    let registry = MetadataSelfWriteRegistry()
    let parser = FakeAssistantQueryParser()
    let viewModel: AssistantViewModel

    init(
        modelParser: (any NaturalLanguageQueryParsing)? = nil,
        availability: @escaping @Sendable () -> AssistantAvailability = { .available },
        includeWriter: Bool = true
    ) {
        let store = store
        let writer = writer
        viewModel = AssistantViewModel(
            proposals: store,
            backends: AssistantBackendStack(fallbackParser: parser, modelParser: modelParser),
            repositories: AssistantRepositoryStack(
                playlists: playlists,
                smartPlaylists: smartPlaylists,
                mixGenerator: mixGenerator,
                metadataWriter: includeWriter ? writer : nil,
                selfWriteRegistry: registry
            ),
            availabilityProbe: availability,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    /// Every mutating repository call served so far — the single number a
    /// "nothing was written" assertion reads.
    var repositoryMutations: Int {
        playlists.recording.mutationCount
    }

    var tagWrites: Int {
        writer.calls.count
    }
}

/// Builders for the value types the harness's tests trade in.
enum AssistantProposalFixture {
    static func draft(_ trackIds: [Int64], sourceKind: MixSourceKind = .rulesResult) -> PlaylistDraft {
        PlaylistDraft(
            entries: trackIds.enumerated().map { index, trackId in
                MixDraftEntry(
                    trackId: trackId,
                    provenance: .rulesResult,
                    score: 1 - Double(index) / Double(max(1, trackIds.count))
                )
            },
            nameHint: MixNameHint(sourceKind: sourceKind, trackCount: trackIds.count)
        )
    }

    static func createProposal(
        trackIds: [Int64],
        name: String = "Fixture Mix",
        profileId: Int64 = 1
    ) -> AIProposal {
        AIProposal(
            profileId: profileId,
            kind: .createPlaylist(CreatePlaylistRequest(draft: draft(trackIds), name: name))
        )
    }

    static func tagProposal(_ patches: [TagPatch], profileId: Int64 = 1) -> AIProposal {
        AIProposal(profileId: profileId, kind: .tagChangeSet(patches: patches))
    }

    static func patch(trackId: Int64, genre: String) -> TagPatch {
        TagPatch(
            trackId: trackId,
            fileURL: URL(fileURLWithPath: "/fixture/\(trackId).flac"),
            patch: WritableMetadata(genre: genre)
        )
    }
}
