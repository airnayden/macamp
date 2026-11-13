// PlayEventCompactionTrigger — the launch/idle driver for ``PlayEventCompactor``.
//
// Compaction is maintenance: it must happen, it must never be on a hot path, and it
// must never be on the audio path. This type is the whole policy — one pass per
// launch, started from the composition root, deferred past the launch burst and run
// at background priority off the main actor. `PlayEventCompactor` itself has no
// schedule of its own, which keeps it a pure, directly-testable operation.
//
// The `hasStarted` latch mirrors ``LyricsSweepService``: the composition root may
// call ``start()`` from a closure that fires more than once (a roots refresh, a
// profile switch) without a second latch of its own.
import Foundation

/// Runs one ``PlayEventCompacting`` pass per launch, off-main and after a delay.
@MainActor
public final class PlayEventCompactionTrigger {
    /// How long after wiring the pass begins.
    ///
    /// Long enough that the first library load, the state restore and the initial
    /// render are all done — compaction competes with nothing the user can see.
    public static let defaultStartDelay: Duration = .seconds(10)

    /// Whether ``start()`` has already latched. Read by the shells' composition
    /// tests to prove the trigger really is wired.
    public private(set) var hasStarted = false

    private let compactor: any PlayEventCompacting
    private let startDelay: Duration
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - compactor: The pass to run.
    ///   - startDelay: How long to wait before running it. Tests pass `.zero`.
    public init(
        compactor: any PlayEventCompacting,
        startDelay: Duration = PlayEventCompactionTrigger.defaultStartDelay
    ) {
        self.compactor = compactor
        self.startDelay = startDelay
    }

    /// Schedules the single compaction pass for this launch.
    ///
    /// Idempotent: later calls are ignored. Returns immediately — the work runs in a
    /// detached background task, so nothing here touches the main actor (let alone
    /// the audio path) beyond flipping the latch.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let compactor = compactor
        let delay = startDelay
        task = Task.detached(priority: .background) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            // A failed pass rolls back whole (see PlayEventCompactor) and is simply
            // retried next launch; there is nothing for a caller to do about it.
            _ = try? await compactor.compact()
        }
    }

    /// Cancels a scheduled or in-flight pass.
    public func cancel() {
        task?.cancel()
    }

    /// Awaits the pass ``start()`` scheduled. Test seam; production never calls it.
    public func waitForCompletion() async {
        await task?.value
    }
}
