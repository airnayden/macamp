// Fixtures for `LibraryChatViewModelTests`, in their own file so the suite stays
// inside `file_length`. Split for that reason alone — do not merge them back.
//
// These are the suite's SYNCHRONISATION, not just its doubles: every case that
// drives a turn parked mid-flight fences on one of them. Read the suite header for
// what each one replaced and why the obvious `isResponding` / `Task.yield()` fences
// were load-sensitive.
import Foundation

/// A call count a test can AWAIT rather than guess at.
///
/// Continuation-based: `wait(untilAtLeast:)` resumes from `increment()` itself, so a
/// fence costs one hop and no elapsed time. `headroom` is the only clock involved and
/// nothing is ever fenced ON it — reaching it always reds the assertion that follows.
actor ChatCallCounter {
    private struct Waiter {
        let ticket: Int
        let needed: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Far beyond any scheduling delay, and FINITE on purpose: a regression that
    /// never signals must FAIL rather than wedge the run. Swift Testing's
    /// `.timeLimit` trait cannot do this job — it cancels, and a task parked in
    /// `withCheckedContinuation` does not observe cancellation (measured: a hung
    /// case survived 30 minutes under a one-minute limit).
    static let headroom: Duration = .seconds(30)

    private(set) var value = 0
    private var waiters: [Waiter] = []
    private var nextTicket = 0

    func increment() {
        value += 1
        let landed = value
        let resumable = waiters.filter { $0.needed <= landed }
        waiters.removeAll { $0.needed <= landed }
        for waiter in resumable {
            waiter.continuation.resume()
        }
    }

    func wait(untilAtLeast needed: Int) async {
        guard value < needed else { return }
        let ticket = nextTicket
        nextTicket += 1
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: ChatCallCounter.headroom)
            await self?.expire(ticket)
        }
        await withCheckedContinuation {
            waiters.append(Waiter(ticket: ticket, needed: needed, continuation: $0))
        }
        expiry.cancel()
    }

    private func expire(_ ticket: Int) {
        guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}

/// The gate a fake tier parks on, and the arrival signal a test fences on.
///
/// Used in BOTH directions, which is the whole synchronisation strategy here.
actor ChatTurnGate {
    private let arrivals = ChatCallCounter()
    private var arrivalCount = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Parks the FIRST caller until ``open()`` and lets every later one straight
    /// through.
    ///
    /// Parking all of them would DEADLOCK instead of failing whenever the busy latch
    /// stops rejecting: the second turn would block on a gate the test can only open
    /// after the first turn returns. Letting the extra caller through turns that
    /// regression into an extra answer, which is a red.
    func wait() async {
        arrivalCount += 1
        let position = arrivalCount
        await arrivals.increment()
        guard position == 1, !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Resumes once `count` callers have REACHED ``wait()``.
    func waitForArrivals(_ count: Int) async {
        await arrivals.wait(untilAtLeast: count)
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed {
            waiter.resume()
        }
    }
}

actor ChatSendRecorder {
    private(set) var texts: [String] = []

    func record(_ text: String) {
        texts.append(text)
    }
}

/// Stands in for the composition root's proposal filer.
@MainActor
final class ChatProposalBox {
    private var ids: [UUID] = []

    func file(_ id: UUID) {
        ids.append(id)
    }

    func drain() -> [UUID] {
        defer { ids.removeAll() }
        return ids
    }
}
