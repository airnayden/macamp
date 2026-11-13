import Foundation
import Services
import Testing

/// A main-actor sink the orchestrator's effect closures write to, so a test can
/// assert the ORDER effects fire in and resolve the "current" root set the way the
/// live roots store would (per active profile).
@MainActor
private final class SwitchRecorder {
    var log: [String] = []
    var rootsByProfile: [Int64: Set<String>]
    var activeProfile: Int64

    init(rootsByProfile: [Int64: Set<String>], active: Int64) {
        self.rootsByProfile = rootsByProfile
        activeProfile = active
    }
}

@MainActor
@Suite("ProfileTests")
struct ProfileSwitchOrchestratorTests {
    private func makeOrchestrator(_ recorder: SwitchRecorder) -> ProfileSwitchOrchestrator {
        ProfileSwitchOrchestrator(
            activeProfileId: recorder.activeProfile,
            cancelPendingPlaybackSave: { recorder.log.append("cancel") },
            flushPlaybackState: { profileId in
                recorder.log.append("flush(\(profileId))")
            },
            restorePlaybackState: { profileId in
                recorder.log.append("restore(\(profileId))")
            },
            stopAndClearPlayback: { recorder.log.append("stop") },
            rescope: { profileId in
                recorder.log.append("rescope(\(profileId))")
                recorder.activeProfile = profileId
            },
            restartObservations: { recorder.log.append("reobserve") },
            currentRootPaths: { recorder.rootsByProfile[recorder.activeProfile] ?? [] },
            runScanAndReconcile: { recorder.log.append("scan") }
        )
    }

    @Test func firesEffectsInOrderThenScansWhenRootsChange() {
        let recorder = SwitchRecorder(rootsByProfile: [1: ["/a"], 2: ["/b"]], active: 1)

        makeOrchestrator(recorder).handleSwitch(toProfileId: 2)

        #expect(recorder.log == [
            "cancel", "flush(1)", "stop", "cancel", "rescope(2)", "reobserve", "scan", "restore(2)",
        ])
    }

    @Test func skipsScanWhenRootSetUnchanged() {
        let recorder = SwitchRecorder(rootsByProfile: [1: ["/shared"], 2: ["/shared"]], active: 1)

        makeOrchestrator(recorder).handleSwitch(toProfileId: 2)

        #expect(recorder.log == [
            "cancel", "flush(1)", "stop", "cancel", "rescope(2)", "reobserve", "restore(2)",
        ])
    }

    @Test func skipsScanWhenNeitherProfileHasRoots() {
        let recorder = SwitchRecorder(rootsByProfile: [:], active: 1)

        makeOrchestrator(recorder).handleSwitch(toProfileId: 2)

        #expect(recorder.log == [
            "cancel", "flush(1)", "stop", "cancel", "rescope(2)", "reobserve", "restore(2)",
        ])
    }

    @Test func flushesOutgoingProfileIdsAcrossBackAndForthSwitches() {
        let recorder = SwitchRecorder(rootsByProfile: [1: ["/a"], 2: ["/b"]], active: 1)
        let orchestrator = makeOrchestrator(recorder)

        orchestrator.handleSwitch(toProfileId: 2)
        orchestrator.handleSwitch(toProfileId: 1)

        #expect(recorder.log == [
            "cancel", "flush(1)", "stop", "cancel", "rescope(2)", "reobserve", "scan", "restore(2)",
            "cancel", "flush(2)", "stop", "cancel", "rescope(1)", "reobserve", "scan", "restore(1)",
        ])
    }
}
