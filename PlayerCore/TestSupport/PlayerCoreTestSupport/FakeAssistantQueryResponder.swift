// FakeAssistantQueryResponder — a scripted ``AssistantQueryResponding``.
//
// Separate from ``FakeAssistantBackends`` on purpose. Those fakes conform to the
// three PUBLIC seams and answer "what did the caller ask the assistant for"; this
// one sits one layer lower, at the single model round-trip, and answers "how did
// the FM backend behave when the model misbehaved". A suite arms a per-call outcome
// script and asserts the exact number of round-trips, which is what makes
// "retried EXACTLY once" a measurement rather than an assumption.
//
// Floor-available, like the seam it conforms to: no FoundationModels, no session,
// no Apple Intelligence, no model assets. The whole retry/busy policy is therefore
// testable on any host.
//
// The release gate is a continuation rather than a sleep. A timed hold would make
// the concurrency test a race between the fake's delay and the test's polling; a
// gate makes "the first request is still in flight" an exact state a test controls.
import Foundation
import os
import Services

/// A scripted single-exchange responder for ``FMAssistantBackend``.
public struct FakeAssistantQueryResponder: AssistantQueryResponding {
    /// One recorded round-trip.
    public struct Request: Sendable, Equatable {
        public var instructions: String
        public var prompt: String

        public init(instructions: String, prompt: String) {
            self.instructions = instructions
            self.prompt = prompt
        }
    }

    /// What one round-trip does.
    public enum Outcome: Sendable {
        /// Return these raw fields.
        case fields(FMQuerySpecFields)
        /// Throw this failure.
        case failure(AssistantFailure)
    }

    /// Everything the fake returns and observes, guarded as one unit.
    public struct Recording: Sendable {
        /// Round-trips, in order.
        public var requests: [Request] = []
        /// Consumed front-first; when empty, ``fallback`` is used.
        public var script: [Outcome] = []
        /// Used once ``script`` is exhausted, so a test scripts only the calls it
        /// cares about and every later call still succeeds.
        public var fallback: Outcome = .fields(FMQuerySpecFields())
    }

    private struct GateState {
        var isHeld = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<Recording>
    private let gate: OSAllocatedUnfairLock<GateState>

    public init(script: [Outcome] = [], fallback: Outcome = .fields(FMQuerySpecFields())) {
        var recording = Recording()
        recording.script = script
        recording.fallback = fallback
        state = OSAllocatedUnfairLock(initialState: recording)
        gate = OSAllocatedUnfairLock(initialState: GateState())
    }

    /// A snapshot of everything recorded so far.
    public var recording: Recording {
        state.withLock { $0 }
    }

    /// How many round-trips have been SERVED (recorded on entry, so a held call is
    /// already counted while it is still in flight).
    public var requestCount: Int {
        state.withLock { $0.requests.count }
    }

    /// Replaces the outcome script.
    public func setScript(_ script: [Outcome]) {
        state.withLock { $0.script = script }
    }

    /// Replaces the post-script outcome.
    public func setFallback(_ outcome: Outcome) {
        state.withLock { $0.fallback = outcome }
    }

    /// Suspends every subsequent round-trip until ``release()``.
    public func hold() {
        gate.withLock { $0.isHeld = true }
    }

    /// Releases the gate and resumes everything waiting on it. Idempotent.
    public func release() {
        let waiters = gate.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.isHeld = false
            let pending = current.waiters
            current.waiters = []
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Spins until at least `count` round-trips have been served, or gives up.
    ///
    /// Yield-based rather than timed: it advances only when the cooperative pool
    /// actually runs the other task, so it cannot pass by sleeping long enough.
    /// Returns `false` on exhaustion so a caller asserts rather than hangs.
    @discardableResult
    public func waitForRequests(atLeast count: Int, iterations: Int = 10000) async -> Bool {
        for _ in 0 ..< iterations {
            if requestCount >= count { return true }
            await Task.yield()
        }
        return requestCount >= count
    }

    public func respondToQuery(instructions: String, prompt: String) async throws -> FMQuerySpecFields {
        let outcome = state.withLock { current -> Outcome in
            current.requests.append(Request(instructions: instructions, prompt: prompt))
            guard !current.script.isEmpty else { return current.fallback }
            return current.script.removeFirst()
        }
        await waitIfHeld()
        switch outcome {
        case let .fields(fields):
            return fields
        case let .failure(failure):
            throw failure
        }
    }

    // MARK: Private

    private func waitIfHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldWait = gate.withLock { current -> Bool in
                guard current.isHeld else { return false }
                current.waiters.append(continuation)
                return true
            }
            if !shouldWait {
                continuation.resume()
            }
        }
    }
}
