// LibraryChatCorrectiveTurnTests — the one-shot nudge behind a playlist ask that
// was answered in prose.
//
// The claim under test is narrow and entirely about COUNTING: a listener who clearly
// asked for a playlist and got sentences instead of a filed proposal is worth exactly
// ONE more directive to the same tier — never two, never one on a turn that already
// filed, and never one at all on a tier that did not opt in.
//
// ── WHY THE ROW COUNT IS ASSERTED EXACTLY, NOT AS A BOUND ────────────────────
//
// The recorded decision is "append a SECOND assistant row", not "merge the corrective
// reply into the first". `<= 2` would pass under either, so the corrective row count
// is pinned at exactly 2 — an implementation that merges must go red here rather than
// quietly reinterpret the decision.
//
// ── HOW THIS SUITE WAITS ─────────────────────────────────────────────────────
//
// Only the reset case drives a turn parked mid-flight, and it fences on a REAL
// transition — the corrective send being entered — rather than on `isResponding` or
// a bare `Task.yield()`, both of which are load-sensitive here for the reasons
// `LibraryChatViewModelTests` records at length. `CorrectiveSendLog.headroom` is the
// hang-breaker behind that fence and is never fenced ON.
import Foundation
import Services
import Testing
import ViewModels

@Suite("LibraryChatViewModel corrective turn")
@MainActor
struct LibraryChatCorrectiveTurnTests {
    // MARK: The correction fires

    @Test("a playlist ask answered in prose alone is corrected exactly once")
    func aProseOnlyPlaylistAskIsCorrectedOnce() async {
        let log = CorrectiveSendLog()
        let model = Self.model(log: log)

        await model.send("make me a playlist for tonight")

        #expect(await log.count == 2)
        #expect(await log.texts.last == LibraryChatViewModel.correctiveDirective)
        #expect(model.messages.count(where: { $0.role == .listener }) == 1)
        #expect(model.messages.count(where: { $0.role == .assistant }) == 2)
    }

    @Test("the directive is sent to the tier and never shown as a listener message")
    func theDirectiveNeverEntersTheTranscript() async {
        let model = Self.model(log: CorrectiveSendLog())

        await model.send("build me a mix for the drive")

        #expect(model.messages.first?.text == "build me a mix for the drive")
        #expect(!model.messages.contains { $0.text == LibraryChatViewModel.correctiveDirective })
    }

    @Test("a proposal filed by the corrective turn lands on its own second row")
    func theCorrectiveRowCarriesItsProposal() async {
        let log = CorrectiveSendLog()
        let filed = UUID()
        let box = CorrectiveProposalBox()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(
                    prewarm: {},
                    send: { text in
                        await log.record(text)
                        if await log.count == 2 { await box.file(filed) }
                        return Self.turn("Here you go.")
                    },
                    supportsCorrectiveFollowUp: true
                ))
            },
            drainFiledProposals: { box.drain() }
        )

        await model.send("make me a playlist for tonight")

        #expect(model.messages.count == 3)
        #expect(model.messages.dropLast().last?.proposalIds.isEmpty == true)
        #expect(model.messages.last?.proposalIds == [filed])
    }

    // MARK: The correction stays quiet

    @Test("a turn that already filed a proposal is never corrected")
    func aFiledProposalSuppressesTheCorrection() async {
        let log = CorrectiveSendLog()
        let filed = UUID()
        let box = CorrectiveProposalBox()
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(
                    prewarm: {},
                    send: { text in
                        await log.record(text)
                        await box.file(filed)
                        return Self.turn("Made you one.")
                    },
                    supportsCorrectiveFollowUp: true
                ))
            },
            drainFiledProposals: { box.drain() }
        )

        await model.send("make me a playlist for tonight")

        #expect(await log.count == 1)
        #expect(model.messages.count == 2)
        #expect(model.messages.last?.proposalIds == [filed])
    }

    @Test("a message that is not a playlist ask is answered once and left alone")
    func aPlainRequestIsNeverCorrected() async {
        let log = CorrectiveSendLog()
        let model = Self.model(log: log)

        await model.send("what is the loudest song I own")

        #expect(await log.count == 1)
        #expect(model.messages.count == 2)
    }

    @Test("a tier that did not opt in is never sent a directive")
    func aTierThatDidNotOptInIsNeverCorrected() async {
        let log = CorrectiveSendLog()
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(
                prewarm: {},
                send: { text in
                    await log.record(text)
                    return Self.turn("Here are some ideas.")
                }
            ))
        })

        await model.send("make me a playlist for tonight")

        #expect(await log.count == 1)
        #expect(model.messages.count == 2)
    }

    // MARK: The generation guard

    @Test("a reset while the corrective turn is in flight drops its answer")
    func aResetDropsTheCorrectiveAnswer() async {
        let log = CorrectiveSendLog()
        let gate = CorrectiveGate()
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(
                prewarm: {},
                send: { text in
                    await log.record(text)
                    if await log.count == 2 { await gate.wait() }
                    return Self.turn("late")
                },
                supportsCorrectiveFollowUp: true
            ))
        })

        let inFlight = Task { await model.send("make me a playlist for tonight") }
        // The corrective send having been ENTERED is what proves the first answer is
        // already on the transcript and the turn's generation is already taken.
        await log.wait(untilAtLeast: 2)
        #expect(model.messages.count == 2)

        model.reset()
        #expect(model.messages.isEmpty)
        await gate.open()
        await inFlight.value

        #expect(model.messages.isEmpty)
        #expect(await log.count == 2)
    }

    // MARK: Fixtures

    /// A tier that answers every message in prose and files nothing.
    private static func model(log: CorrectiveSendLog) -> LibraryChatViewModel {
        LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(
                prewarm: {},
                send: { text in
                    await log.record(text)
                    return Self.turn("Here are some ideas.")
                },
                supportsCorrectiveFollowUp: true
            ))
        })
    }

    /// `nonisolated` because the fakes above build a reply from inside a `@Sendable`
    /// send closure, which does not run on the main actor.
    private nonisolated static func turn(_ text: String) -> LibraryChatReply {
        LibraryChatReply(turn: AssistantChatTurn(text: text))
    }
}

// MARK: - Fences

/// Every text the fake tier was sent, with a fence on the Nth one.
///
/// Continuation-based rather than polled: `wait(untilAtLeast:)` resumes from
/// `record` itself, so a fence costs one hop and no elapsed time. `headroom` is the
/// only clock involved and nothing is ever fenced ON it — reaching it always reds
/// the assertion that follows.
actor CorrectiveSendLog {
    /// Far beyond any scheduling delay, and FINITE on purpose: a regression that
    /// never signals must FAIL rather than wedge the run.
    static let headroom: Duration = .seconds(30)

    private struct Waiter {
        let needed: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var texts: [String] = []
    private var waiters: [Waiter] = []

    var count: Int {
        texts.count
    }

    func record(_ text: String) {
        texts.append(text)
        let landed = texts.count
        let resumable = waiters.filter { $0.needed <= landed }
        waiters.removeAll { $0.needed <= landed }
        for waiter in resumable {
            waiter.continuation.resume()
        }
    }

    func wait(untilAtLeast needed: Int) async {
        guard texts.count < needed else { return }
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: CorrectiveSendLog.headroom)
            await self?.expire()
        }
        await withCheckedContinuation { waiters.append(Waiter(needed: needed, continuation: $0)) }
        expiry.cancel()
    }

    private func expire() {
        let stranded = waiters
        waiters.removeAll()
        for waiter in stranded {
            waiter.continuation.resume()
        }
    }
}

/// The gate a fake tier parks on so a test can reset beneath it.
actor CorrectiveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Stands in for the composition root's proposal filer.
@MainActor
final class CorrectiveProposalBox {
    private var ids: [UUID] = []

    func file(_ id: UUID) {
        ids.append(id)
    }

    func drain() -> [UUID] {
        defer { ids.removeAll() }
        return ids
    }
}
