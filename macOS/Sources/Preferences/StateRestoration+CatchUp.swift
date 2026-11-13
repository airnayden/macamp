// StateRestoration+CatchUp — the background half of launch.
//
// Split out of `StateRestoration.swift`, which sits at the SwiftLint `file_length`
// ceiling. The two flags this method owns stay in the class body over there:
// Swift forbids stored properties in an extension.
import Foundation
import Services

extension StateRestorationController {
    /// Publishes what the database already holds, starts FSEvents, then lets the
    /// catch-up scan and availability reconcile finish in the background.
    /// Idempotent — only the first call does the work.
    ///
    /// Runs in a detached task retained by ``catchUpTask``, NEVER as a child of the
    /// splash view's `.task`: startup changes that view's identity, which cancels its
    /// whole task tree, and a cancelled catch-up leaves the library silently stale.
    func beginCatchUp() {
        guard !hasBegunCatchUp else { return }
        hasBegunCatchUp = true
        // The body is a separate `@MainActor` method rather than an inline
        // `{ @MainActor [self] in }` closure: the region-based isolation checker
        // rejects that combination inside `Task.detached`.
        catchUpTask = Task.detached { [self] in
            await runCatchUpSequence()
        }
    }

    private func runCatchUpSequence() async {
        environment.libraryFolders.publishProjections()
        await environment.libraryFolders.startWatchingAndScheduleCatchUp()
        await environment.libraryFolders.waitForIdle()
        // post-catch-up: work that must observe the caught-up library.
        //
        // The sweep opens every audio file it probes, so a pass raised by the
        // launch content refresh would have competed with the scan above. Latching
        // the flag hands every LATER pass back to that refresh; this one is ours.
        environment.libraryFolders.markLaunchCatchUpComplete()
        environment.lyricsSweep.start()
        await refreshGeneratedPlaylistsIfStale()
    }
}
