// TerminationRace — bound an async flush by a deadline.
//
// Deliberately NOT a `withTaskGroup` race: `await someTask.value` on a
// `Task<Void, Never>` ignores cancellation, so a group would keep waiting for the
// child it just cancelled and the timeout would buy nothing. A one-shot signal
// either side can trip is the only shape that actually bounds the wait.
//
// AppKit-free by design, so the semantics can be exercised without an app host.
import Foundation

/// Runs an async flush with a hard deadline, returning as soon as either settles.
@MainActor
enum TerminationRace {
    static func run(_ flush: @escaping @MainActor () async -> Void, timeout: Duration) async {
        let settled = TerminationSignal()
        Task { @MainActor in
            await flush()
            settled.trip()
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            settled.trip()
        }
        await settled.wait()
    }
}

/// A one-shot main-actor signal: the first ``trip()`` releases every waiter, and
/// any later ``wait()`` returns immediately.
@MainActor
final class TerminationSignal {
    private var hasTripped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func trip() {
        guard !hasTripped else { return }
        hasTripped = true
        let resumable = waiters
        waiters.removeAll()
        for waiter in resumable {
            waiter.resume()
        }
    }

    func wait() async {
        guard !hasTripped else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
