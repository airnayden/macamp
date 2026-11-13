// LibraryChatLiveSmokeTests — a REAL `LanguageModelSession`, holding a real
// multi-turn conversation, calling real tools over a seeded fixture database.
//
// Everything else in this wave is hermetic; this is the one suite that proves the
// wiring actually works end to end. Without it, five wrappers, an instructions
// string and a context policy could all be individually correct and still never
// produce a tool call.
//
// ── WHAT IS ASSERTED, AND WHAT DELIBERATELY IS NOT ───────────────────────────
//
// A language model's WORDING is not deterministic, so nothing here asserts on
// phrasing. What IS deterministic is whether the model reached for a tool: a
// `.toolCalls` transcript entry either exists or it does not, and the tool's own
// answer is a fixed string this repo rendered from a fixed database. So the
// assertions are:
//
//   • at least one tool was invoked, and it came from the published five;
//   • the tool's RESULT — the `.toolResult` event's summary, which is W1's own
//     rendered text — carries the seeded library;
//   • the second turn proves statefulness: the transcript still holds the first
//     turn, which is the whole difference between this tier and the single-shot
//     ``FMSessionQueryResponder``.
//
// A test that asserted "the answer mentions Jazz" would be a flake generator.
//
// ── THIS SUITE SKIPS RATHER THAN FAILS WHEN THE MODEL IS ABSENT ──────────────
//
// `@available` is a COMPILE/OS gate and is never a capability proxy — capability
// is `SystemLanguageModel.default.availability`, exactly as
// `AssistantAvailability.swift`'s header requires. CI runners have no Apple
// Intelligence, so an unavailable model prints the reason and returns. On a
// machine where the model IS available (this one: macOS 26.5.1, availability
// `.available`, `contextSize` 4096) the assertions run for real.
//
// ── SERIALIZED, AND WITH A TIME LIMIT ────────────────────────────────────────
//
// `.serialized` because `GenerationError.concurrentRequests` is a real, documented
// failure and two cases racing the one on-device model would produce it. The time
// limit bounds a hung inference so the gate reports a failure instead of stalling
// silently.
import Foundation
import Persistence
import Services
import Testing

#if canImport(FoundationModels)
    import FoundationModels

    @Suite("LibraryChat live smoke", .serialized, .timeLimit(.minutes(5)))
    struct LibraryChatLiveSmokeTests {
        /// The capability gate. Returns `nil` — printing the reason — when this
        /// host cannot run the model.
        @available(macOS 26, iOS 26, *)
        private static func liveSession(_ toolbox: LibraryToolbox) -> LibraryChatSession? {
            let outcome = LibraryChatSession.make(
                toolbox: toolbox,
                locale: Locale(identifier: "en_US"),
                intelligenceEnabled: true
            )
            switch outcome {
            case let .success(session):
                return session
            case let .failure(unavailable):
                print("[live-smoke] SKIPPED — on-device model unavailable: \(unavailable.reason)")
                return nil
            }
        }

        @Test("A genre question drives a real tool call, and a second turn sees the first")
        func holdsAToolCallingConversation() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            guard let session = Self.liveSession(toolbox) else { return }

            #expect(session.toolNames == LibraryToolbox.onDeviceToolNames)
            await session.prewarm()

            let first = try await session.send("Which genres are in my library, and how many tracks does each have?")
            let firstNames = first.calledToolNames
            print("[live-smoke] turn 1 tools: \(firstNames)")
            print("[live-smoke] turn 1 text: \(first.text)")
            #expect(!firstNames.isEmpty, "the model answered a library question without any lookup")
            #expect(Set(firstNames).isSubset(of: Set(LibraryToolbox.onDeviceToolNames)))

            // The RESULT is W1's own rendered text over a fixed database, so this is
            // an assertion about the plumbing, not about the model's prose.
            let summaries = first.events.compactMap { event -> String? in
                if case let .toolResult(_, summary, _, _, _) = event { return summary }
                return nil
            }
            print("[live-smoke] turn 1 tool results: \(summaries)")
            #expect(!summaries.isEmpty, "a tool was called but no result event was derived")
            let seeded = ["Jazz", "Ambient", "Electronic", "Aurora Drift", "Crimson Pulse", "Ember Waltz"]
            let carriesSeededData = summaries.contains(where: { summary in
                seeded.contains(where: summary.contains)
            })
            #expect(carriesSeededData, "no tool result carried the seeded library: \(summaries)")

            // STATEFULNESS. A second `send` is interpreted against the first — the
            // entire difference between this tier and the single-shot one, and the
            // reason the session is a stored property rather than a per-request local.
            let before = await session.transcript
            let second = try await session.send("Of those, which one has the fewest tracks?")
            let after = await session.transcript
            print("[live-smoke] turn 2 tools: \(second.calledToolNames)")
            print("[live-smoke] turn 2 text: \(second.text)")
            print("[live-smoke] transcript entries: \(before.count) -> \(after.count)")
            #expect(after.count > before.count, "the second turn did not extend the transcript")

            let keptFirstPrompt = after.contains(where: { entry in
                if case let .prompt(text) = entry { return text.contains("Which genres") }
                return false
            })
            #expect(keptFirstPrompt, "the first turn's prompt was lost, so the session is not multi-turn")
            #expect(!second.text.isEmpty || !second.calledToolNames.isEmpty)

            for entry in after {
                print("[live-smoke] transcript: \(entry)")
            }
        }

        @Test("A second send while the first is in flight is REJECTED, not queued")
        func rejectsAConcurrentSend() async throws {
            guard #available(macOS 26, iOS 26, *) else { return }
            let toolbox = try ToolboxFixtures.makeToolbox(ToolboxFixtures.makeLibrary())
            guard let session = Self.liveSession(toolbox) else { return }

            // A listener typing a second request wants to know it was not accepted,
            // not to wait an unbounded time behind the first. Same policy, and the
            // same latch construction, as `FMAssistantBackend.parse`.
            async let first: AssistantChatTurn = session.send("List my genres.")
            var rejected = false
            for _ in 0 ..< 300 {
                if await session.isResponding {
                    await #expect(throws: AssistantFailure.busy) {
                        try await session.send("And again.")
                    }
                    rejected = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = try await first
            #expect(rejected, "the first turn never reported itself as responding")
        }
    }
#endif
