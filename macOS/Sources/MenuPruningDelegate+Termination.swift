// MenuPruningDelegate+Termination — the quit-time flush.
//
// Listening history is written off the main actor, so at quit there is normally a
// database write still in flight. AppKit's only hook for "wait before you die" is
// `applicationShouldTerminate` returning `.terminateLater`, and the app may install
// exactly ONE `NSApplicationDelegate` (`@NSApplicationDelegateAdaptor`) — which is
// why this lives on the menu-pruning delegate rather than in an adaptor of its own.
//
// The flush is raced against a timeout and the reply is issued either way: losing a
// few seconds of history is acceptable, an app that will not quit is not.
import AppKit
import Foundation

extension MenuPruningDelegate {
    /// The reply-agnostic core of `applicationShouldTerminate(_:)`.
    ///
    /// Split out so tests can drive the whole termination path without an
    /// `NSApplication` — sending a real `reply(toApplicationShouldTerminate:)`
    /// outside a real quit would terminate the test host.
    ///
    /// Returns `.terminateNow` when no flush is installed (a quit during the
    /// splash, before the composition root exists) so termination can never hang
    /// on a handler that was never assigned.
    func beginTermination(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard let terminationFlush else { return .terminateNow }
        pendingTerminationReplies.append(reply)
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        let timeout = terminationFlushTimeout
        Task { @MainActor [weak self] in
            await TerminationRace.run(terminationFlush, timeout: timeout)
            self?.drainTerminationReplies()
        }
        return .terminateLater
    }

    private func drainTerminationReplies() {
        let replies = pendingTerminationReplies
        pendingTerminationReplies.removeAll()
        for reply in replies {
            reply(true)
        }
    }
}
