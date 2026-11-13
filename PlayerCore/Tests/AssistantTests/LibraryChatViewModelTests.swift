// LibraryChatViewModelTests — the conversation surface, driven with fake tiers.
//
// The engine seam is two closures, so every case here is exact: a test decides what
// the tier returns, how long it takes and whether it throws, with no model, no
// network, no macOS 26 and no test-double type at all.
//
// ── HOW THIS SUITE WAITS, AND WHAT IT MUST NOT WAIT ON ───────────────────────
//
// Three cases drive a turn that is deliberately parked mid-flight, so each one has
// to fence on the transition it is actually about. Two fences used to be wrong and
// were LOAD-SENSITIVE — 4 runs red in 12 at load average 17-38:
//
//   * `while !model.isResponding { await Task.yield() }` — the latch is set in
//     `send` BEFORE the turn's `Task` runs, so it proves nothing about the listener
//     row having been appended or the generation having been captured. Reds as
//     `messages → []` and as a stale answer surviving a reset.
//   * `await Task.yield()` after `prewarm()` — one yield is one chance for a task
//     that has to hop to an actor. Reds as `value → 1` where 2 was due.
//
// So a fence is now a REAL transition published by the thing under test: the tier's
// own `send` being entered (``ChatTurnGate/waitForArrivals(_:)``) or a prewarm
// actually landing (``ChatCallCounter/wait(untilAtLeast:)``). Both are continuations
// — no sleeping, no polling, no elapsed time anywhere. Their finite
// ``ChatCallCounter/headroom`` is the hang-breaker behind them, never a fence.
import Foundation
import Services
import Testing
import ViewModels

@Suite("LibraryChatViewModel")
@MainActor
struct LibraryChatViewModelTests {
    // MARK: Fakes

    /// A tier that answers immediately with a fixed reply.
    private static func answering(
        _ reply: LibraryChatReply,
        prewarms: ChatCallCounter? = nil,
        sends: ChatSendRecorder? = nil
    ) -> LibraryChatEngine {
        LibraryChatEngine(
            prewarm: { await prewarms?.increment() },
            send: { text in
                await sends?.record(text)
                return reply
            }
        )
    }

    /// `nonisolated` because two fakes below build a reply from inside a `@Sendable`
    /// send closure, which does not run on the main actor.
    private nonisolated static func turn(
        _ text: String,
        _ events: [AssistantChatEvent] = []
    ) -> LibraryChatReply {
        LibraryChatReply(turn: AssistantChatTurn(text: text, events: events))
    }

    // MARK: A turn

    @Test("a turn appends the listener's message and the assistant's answer, in order")
    func aTurnAppendsBothRows() async {
        let model = LibraryChatViewModel(makeEngine: { .success(Self.answering(Self.turn("Try these."))) })
        await model.send("something jazzy")
        #expect(model.messages.count == 2)
        #expect(model.messages.first?.role == .listener)
        #expect(model.messages.first?.text == "something jazzy")
        #expect(model.messages.last?.role == .assistant)
        #expect(model.messages.last?.text == "Try these.")
    }

    @Test("tool events survive onto the assistant row, in call order")
    func toolEventsReachTheRow() async {
        let reply = Self.turn("Here you go.", [
            .toolCall(name: "list_genres"),
            .toolResult(name: "list_genres", summary: "Jazz (12)", resultCount: nil),
            .toolCall(name: "sample_tracks"),
        ])
        let model = LibraryChatViewModel(makeEngine: { .success(Self.answering(reply)) })
        await model.send("jazz please")
        #expect(model.messages.last?.calledToolNames == ["list_genres", "sample_tracks"])
    }

    @Test("a blank or whitespace-only message is not a turn")
    func blankMessagesAreIgnored() async {
        let model = LibraryChatViewModel(makeEngine: { .success(Self.answering(Self.turn("x"))) })
        await model.send("   \n ")
        #expect(model.messages.isEmpty)
    }

    @Test("a message longer than the budget is clamped, not refused")
    func aLongMessageIsClamped() async {
        let sends = ChatSendRecorder()
        let model = LibraryChatViewModel(
            makeEngine: { .success(Self.answering(Self.turn("ok"), sends: sends)) }
        )
        await model.send(String(repeating: "a", count: LibraryChatViewModel.maxRequestLength + 200))
        let sent = await sends.texts.first
        #expect(sent?.count == LibraryChatViewModel.maxRequestLength)
        #expect(model.messages.count == 2)
    }

    // MARK: The busy latch

    @Test("a second send while one is in flight is REJECTED, not queued")
    func theBusyLatchRejects() async {
        let gate = ChatTurnGate()
        let sends = ChatSendRecorder()
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(
                prewarm: {},
                send: { text in
                    await sends.record(text)
                    await gate.wait()
                    return Self.turn("first")
                }
            ))
        })
        let first = Task { await model.send("one") }
        // The tier being entered is what proves the first turn is in flight; the
        // `isResponding` latch this used to spin on is set a hop earlier, while
        // `messages` is still empty.
        await gate.waitForArrivals(1)
        #expect(model.isResponding)
        #expect(model.messages.map(\.text) == ["one"])
        await model.send("two")
        #expect(model.messages.map(\.text) == ["one"])
        await gate.open()
        await first.value
        #expect(model.messages.map(\.text) == ["one", "first"])
        #expect(await sends.texts == ["one"])
    }

    @Test("the latch clears once the turn finishes, so the next send is accepted")
    func theLatchClears() async {
        let model = LibraryChatViewModel(makeEngine: { .success(Self.answering(Self.turn("a"))) })
        await model.send("one")
        #expect(!model.isResponding)
        await model.send("two")
        #expect(model.messages.count == 4)
    }

    // MARK: Failure

    @Test("an unavailable tier is reported as a row, not swallowed")
    func anUnavailableTierIsReported() async {
        let model = LibraryChatViewModel(makeEngine: { .failure(.unavailable(.deviceNotEligible)) })
        await model.send("hello")
        #expect(model.messages.last?.failure == .unavailable(.deviceNotEligible))
    }

    @Test("a refusal for want of consent keeps its own case rather than collapsing to a generic failure")
    func aConsentRefusalKeepsItsCase() async {
        let model = LibraryChatViewModel(makeEngine: { .failure(.consentRequired) })
        await model.send("hello")
        #expect(model.messages.last?.failure == .consentRequired)
    }

    @Test("a thrown AssistantChatUnavailable keeps its typed reason")
    func aThrownUnavailableKeepsItsReason() async {
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(
                prewarm: {},
                send: { _ in throw AssistantChatUnavailable(reason: .modelNotReady) }
            ))
        })
        await model.send("hello")
        #expect(model.messages.last?.failure == .unavailable(.modelNotReady))
    }

    @Test("any other error is one sentence, not four")
    func anyOtherErrorIsGeneric() async {
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(prewarm: {}, send: { _ in throw AssistantFailure.throttled }))
        })
        await model.send("hello")
        #expect(model.messages.last?.failure == .answerFailed)
    }

    @Test("a cancelled turn says nothing at all")
    func aCancelledTurnIsSilent() async {
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(prewarm: {}, send: { _ in throw CancellationError() }))
        })
        await model.send("hello")
        #expect(model.messages.count == 1)
        #expect(model.messages.last?.role == .listener)
    }

    @Test("an unavailable factory is retried on the next send, because availability is live")
    func anUnavailableFactoryIsNotCached() async {
        let attempts = ChatCallCounter()
        let model = LibraryChatViewModel(makeEngine: {
            Task { await attempts.increment() }
            return .failure(.unavailable(.modelNotReady))
        })
        await model.send("one")
        await model.send("two")
        #expect(model.messages.count(where: { $0.failure != nil }) == 2)
    }

    // MARK: Reset

    @Test("reset clears the transcript AND discards the tier, so the next send builds a new one")
    func resetDiscardsTheEngine() async {
        let built = ChatCallCounter()
        let model = LibraryChatViewModel(makeEngine: {
            Task { await built.increment() }
            return .success(Self.answering(Self.turn("hi")))
        })
        await model.send("one")
        await model.send("two")
        // The factory counts from a detached task, so the count has to be awaited for
        // the same reason the prewarm one does — it is not readable on return.
        await built.wait(untilAtLeast: 1)
        #expect(await built.value == 1)
        model.reset()
        #expect(model.messages.isEmpty)
        await model.send("three")
        await built.wait(untilAtLeast: 2)
        #expect(await built.value == 2)
    }

    @Test("a reset while a turn is in flight drops that turn's answer")
    func theGenerationGuardDropsAStaleAnswer() async {
        let gate = ChatTurnGate()
        let model = LibraryChatViewModel(makeEngine: {
            .success(LibraryChatEngine(
                prewarm: {},
                send: { _ in
                    await gate.wait()
                    return Self.turn("stale")
                }
            ))
        })
        let inFlight = Task { await model.send("one") }
        // A reset that lands before the turn reads `generation` is CAPTURED by that
        // turn rather than invalidating it, and the stale answer survives. Entering
        // the tier proves the generation is already taken.
        await gate.waitForArrivals(1)
        #expect(model.messages.map(\.text) == ["one"])
        model.reset()
        #expect(model.messages.isEmpty)
        await gate.open()
        await inFlight.value
        #expect(model.messages.isEmpty)
    }

    // MARK: Prewarm

    @Test("prewarm runs once per conversation and re-arms after a reset")
    func prewarmRunsOncePerConversation() async {
        let prewarms = ChatCallCounter()
        let model = LibraryChatViewModel(
            makeEngine: { .success(Self.answering(Self.turn("hi"), prewarms: prewarms)) }
        )
        model.prewarm()
        model.prewarm()
        model.prewarm()
        await prewarms.wait(untilAtLeast: 1)
        #expect(await prewarms.value == 1)
        model.reset()
        model.prewarm()
        await prewarms.wait(untilAtLeast: 2)
        #expect(await prewarms.value == 2)
        // A turn is a full round trip through the same engine and must not re-warm,
        // so any prewarm the latch failed to suppress has landed by here.
        await model.send("still just the two")
        #expect(await prewarms.value == 2)
    }

    @Test("prewarm on an unavailable tier does nothing and does not cache the refusal")
    func prewarmOnAnUnavailableTierIsInert() {
        let model = LibraryChatViewModel(makeEngine: { .failure(.unavailable(.osTooOld)) })
        model.prewarm()
        #expect(model.messages.isEmpty)
    }

    // MARK: Proposals and truncation

    @Test("proposals filed during a turn land on that turn's row, and only that one")
    func filedProposalsAttachToTheirTurn() async {
        let filed = UUID()
        let box = ChatProposalBox()
        // The tool files WHILE the turn runs, which is the only moment the real
        // `LibraryChatProposalFiler` ever appends. Pre-loading the box instead would
        // test the wrong thing: ids left over from a previous turn are deliberately
        // discarded before a new one starts.
        let model = LibraryChatViewModel(
            makeEngine: {
                .success(LibraryChatEngine(
                    prewarm: {},
                    send: { _ in
                        await box.file(filed)
                        return Self.turn("Made you one.")
                    }
                ))
            },
            drainFiledProposals: { box.drain() }
        )
        await model.send("make me a playlist")
        #expect(model.messages.last?.proposalIds == [filed])
        await model.send("and another")
        #expect(model.messages.last?.proposalIds == [filed])
        #expect(model.messages.count == 4)
    }

    @Test("ids left unclaimed by a previous turn are never attributed to the next one")
    func staleProposalIdsAreDiscarded() async {
        let stale = UUID()
        let box = ChatProposalBox()
        await box.file(stale)
        let model = LibraryChatViewModel(
            makeEngine: { .success(Self.answering(Self.turn("Nothing filed here."))) },
            drainFiledProposals: { box.drain() }
        )
        await model.send("hello")
        #expect(model.messages.last?.proposalIds.isEmpty == true)
    }

    @Test("a turn that exhausted its lookup budget is marked, and still keeps its answer")
    func truncationIsCarriedOntoTheRow() async {
        let reply = LibraryChatReply(turn: AssistantChatTurn(text: "Partial."), isTruncated: true)
        let model = LibraryChatViewModel(makeEngine: { .success(Self.answering(reply)) })
        await model.send("hello")
        #expect(model.messages.last?.isTruncated == true)
        #expect(model.messages.last?.text == "Partial.")
    }
}
