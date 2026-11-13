// AppEnvironment+ProfileSwitch — wires the active-profile-change seam.
//
// Split out of `AppEnvironment.swift` to keep that composition-root file under the
// SwiftLint `file_length` budget. `wireProfileSwitch` builds a
// `ProfileSwitchOrchestrator` (the testable, ordered switch logic in PlayerCore)
// with the REAL effects and installs it on `profileService.onActiveProfileChanged`.
import Foundation
import Persistence
import Services
import ViewModels

extension Notification.Name {
    static let profilePlaybackStateDidRestore = Notification.Name(
        "com.example.macamp.profilePlaybackStateDidRestore"
    )
}

enum ProfilePlaybackRestoreNotification {
    static let profileIdKey = "profileId"
}

extension AppEnvironment {
    /// Installs the ordered profile-switch orchestration on ``profileService``.
    /// `onActiveProfileChanged` fires only on a real switch, so re-selecting the
    /// active profile runs nothing. The orchestrator flushes the outgoing
    /// playback state, clears playback, rescopes, restarts observations, then
    /// restores the incoming snapshot after the switch completes; root reconcile
    /// stays skipped when the root set is unchanged.
    static func wireProfileSwitch(environment: AppEnvironment) {
        let rootsState = ProfileSwitchRootsState()
        let orchestrator = ProfileSwitchOrchestrator(
            activeProfileId: environment.profileService.activeProfile.id ?? ProfileRecord.guestID,
            cancelPendingPlaybackSave: { [weak environment] in
                environment?.playbackStatePersister.cancelPending()
            },
            flushPlaybackState: { [weak environment] profileId in
                environment?.playbackStatePersister.flushNow(profileId: profileId)
            },
            restorePlaybackState: { [weak environment] profileId in
                Task { @MainActor in
                    await Self.restoreProfilePlaybackState(environment: environment, profileId: profileId)
                }
            },
            stopAndClearPlayback: { [weak environment] in
                // NOT `queue.removeAll()`: that reaches the coordinator's teardown
                // but stamps the interrupted play `.stopped`. Going through the
                // coordinator records it as a profile switch first, then performs
                // the very same teardown; the view model still needs its refresh.
                environment?.coordinator.stopForProfileSwitch()
                environment?.queue.refresh()
            },
            rescope: { [weak environment] profileId in
                guard let environment else { return }
                Self.rescope(environment, to: profileId, rootsState: rootsState)
            },
            restartObservations: { [weak environment] in
                guard let environment else { return }
                environment.library.stopObservingRecentlyAdded()
                environment.library.startObservingRecentlyAdded()
                if !rootsState.changed { environment.libraryFolders.refreshProfileScope() }
                Task { try? await environment.playlists.loadInitialPlaylists() }
                Task { try? await environment.lyricsBrowser.loadInitial() }
            },
            currentRootPaths: { [weak environment] in
                Set((environment?.rootsStore.load() ?? []).map(\.path))
            },
            runScanAndReconcile: { [weak environment] in
                environment?.libraryFolders.reconcileProfileScope()
            }
        )
        environment.profileService.onActiveProfileChanged = { [orchestrator] profile in
            orchestrator.handleSwitch(toProfileId: profile.id ?? ProfileRecord.guestID)
        }
    }

    /// Re-points every profile-owned reader at `profileId`, then retargets the
    /// folder watcher, recording whether the root set actually changed.
    private static func rescope(
        _ environment: AppEnvironment,
        to profileId: Int64,
        rootsState: ProfileSwitchRootsState
    ) {
        let previousRoots = Set(environment.libraryAccess.roots.map(\.url.path))
        // The outgoing play is already committed under the outgoing id; everything
        // from here belongs to the incoming profile. Restore never fires
        // `onTrackStarted`, so nothing else would re-point it.
        environment.playEventRecorder.rescope(to: profileId)
        environment.playSegmentTracker.rescope(to: profileId)
        environment.library.activeProfileId = profileId
        environment.search.activeProfileId = profileId
        environment.playlists.activeProfileId = profileId
        // The previewed track belongs to the OUTGOING profile's library.
        environment.lyricsBrowser.clearPreview()
        environment.lyricsBrowser.activeProfileId = profileId
        environment.rootsStore.activeProfileId = profileId
        environment.libraryAccess.reloadRoots()
        let roots = environment.libraryAccess.roots.map(\.url)
        rootsState.changed = previousRoots != Set(roots.map(\.path))
        environment.watchService.updateRoots(roots)
    }

    @MainActor
    private static func restoreProfilePlaybackState(environment: AppEnvironment?, profileId: Int64) async {
        guard let environment else { return }
        guard environment.profileService.activeProfile.id ?? ProfileRecord.guestID == profileId else { return }
        environment.recordPlaybackSource(nil)

        let isActiveProfile: @MainActor @Sendable () -> Bool = { [weak environment] in
            environment?.profileService.activeProfile.id ?? ProfileRecord.guestID == profileId
        }
        let restorer = PlaybackStateRestorer(
            environment: environment,
            profileId: profileId,
            shouldApply: isActiveProfile
        )
        guard await restorer.restore(profileId: profileId), isActiveProfile() else { return }
        environment.queue.refresh()
        NotificationCenter.default.post(
            name: .profilePlaybackStateDidRestore,
            object: environment,
            userInfo: [ProfilePlaybackRestoreNotification.profileIdKey: profileId]
        )
    }
}

@MainActor
private final class ProfileSwitchRootsState {
    var changed = false
}
