// withDeadline — bounds an ENTIRE connector call, not just its HTTP round-trip.
//
// ── WHY A SECOND DEADLINE EXISTS AT ALL ────────────────────────────────────────
//
// `URLSessionTransport` already times requests out. It cannot, however, see any of
// the awaits that surround one: an async API-key provider, a Keychain read that
// blocks on a locked keychain, an OAuth refresh that itself performs a round-trip,
// or a retry loop that restarts the clock. Those add up, and the assistant holds a
// single-in-flight busy latch while they do. So a bridge conformer wraps its whole
// body — credentials, refresh and HTTP together — in this helper.
//
// ── COOPERATIVE CANCELLATION IS A PRECONDITION ─────────────────────────────────
//
// `withThrowingTaskGroup` re-awaits every child when its scope exits. That makes
// the race below correct for a COOPERATIVE operation — one whose awaits observe
// cancellation, which is true of `URLSession`, `Task.sleep`, and every kit
// conformer — and WRONG for one that parks in a continuation it never resumes:
// cancelling such a child does not unblock it, so scope exit would wait forever.
//
// That is not a gap, it is a layering decision. This helper guards MacAMP's own
// conformers, where cooperativeness is enforced by the ``AIProviderConnector``
// contract. Defending against a hostile third-party conformer is the ASSISTANT
// LADDER's job, and it already does so with a different shape:
// `AssistantViewModel.connectorSpec` races unstructured tasks through an
// `AsyncStream` mailbox so it can cancel AND ABANDON a child that ignores
// cancellation. Two layers, two threat models — do not collapse them.
import Foundation

/// Runs `operation`, failing with ``ConnectorFailure/timeout`` if it has not
/// finished within `seconds`.
///
/// The loser of the race is cancelled: when the deadline wins, the operation's
/// task is cancelled before this function returns, so a cooperative operation
/// stops doing work rather than running on in the background. When the operation
/// wins, the timer is cancelled.
///
/// Errors thrown by `operation` propagate UNCHANGED — a `.unreachable` stays
/// `.unreachable` and is never laundered into `.timeout`. Cancellation of the
/// surrounding task likewise propagates as `CancellationError`, so callers can
/// tell "the listener navigated away" from "the provider is slow".
///
/// - Parameters:
///   - seconds: The budget. Values `<= 0` fail immediately with `.timeout`.
///   - operation: The work to bound. Must be cancellation-cooperative — see this
///     file's header.
public func withDeadline<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(max(0, seconds)))
            throw ConnectorFailure.timeout
        }
        // Cancels the loser on every exit path — value, timeout, or a real failure
        // thrown by `operation` before the timer fired.
        defer { group.cancelAll() }
        guard let winner = try await group.next() else {
            throw ConnectorFailure.timeout
        }
        return winner
    }
}
