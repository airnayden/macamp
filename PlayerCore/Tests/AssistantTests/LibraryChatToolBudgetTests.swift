// LibraryChatToolBudgetTests — the MEASUREMENT behind "five library tools plus
// three control tools", taken with the SDK's own tokenizer rather than estimated.
//
// ── WHY THIS IS A TEST AND NOT A ONE-OFF SCRIPT ──────────────────────────────
//
// The on-device tool count is the single number this tier is most likely to get
// wrong, and the cost of getting it wrong is invisible: a session whose
// instructions plus tool definitions eat the window does not fail, it just runs
// out of room to hold a conversation and starts condensing on turn two. A recorded
// figure in a notepad would go stale the first time a tool description changed.
//
// So the figure is re-measured on every run that CAN measure it, against the real
// `SystemLanguageModel.default.contextSize`. The assertion is on the BUDGET
// FRACTION, not on an absolute token count: the tokenizer is Apple's and may
// change, and what matters is that the definitions leave the conversation room —
// the same property `LibraryChatBudget.condensationFraction` is chosen for.
//
// ── IT SKIPS RATHER THAN FAILS WHERE IT CANNOT MEASURE ───────────────────────
//
// `tokenCount(for:)` is macOS 26.4+ with no back-deployment, and Apple
// Intelligence can be switched off. Both are environment facts, not regressions,
// and `LibraryChatBudget.estimatedTokens(forCharacters:)` is the shipped fallback
// for exactly them — so this suite returns early instead of going red on a machine
// that was never going to run the on-device tier anyway.
import Foundation
import Persistence
import Services
import Testing

#if canImport(FoundationModels)
    import FoundationModels

    @Suite("LibraryChat tool budget", .serialized)
    struct LibraryChatToolBudgetTests {
        /// The share of the window the instructions and tool definitions may take.
        ///
        /// A THIRD, deliberately tighter than
        /// ``LibraryChatBudget/condensationFraction``: that half is where a
        /// transcript starts being condensed, and a fixed prefix that already sat
        /// at the condensation threshold would condense on the first turn, every
        /// turn, forever.
        static let prefixBudgetFraction = 1.0 / 3.0

        @Test("the granted eight-tool prefix still leaves the window room to converse")
        @available(macOS 26.4, iOS 26.4, *)
        func theGrantedPrefixFitsTheWindow() async throws {
            guard case .available = AssistantAvailabilityProbe.current(intelligenceEnabled: true) else { return }
            let database = try ToolboxFixtures.makeLibrary()
            let (granted, _) = ToolboxFixtures.makeControllableToolbox(database)
            let ungranted = ToolboxFixtures.makeToolbox(database)

            let five = try await Self.prefixTokens(ungranted)
            let eight = try await Self.prefixTokens(granted)
            let window = SystemLanguageModel.default.contextSize

            // Printed so the figures land in the evidence file rather than only in
            // a pass/fail bit — the decisions entry quotes them.
            print("[tool-budget] contextSize=\(window) fiveTools=\(five) eightTools=\(eight)")

            #expect(eight > five, "adding three tool definitions must cost something measurable")
            #expect(
                Double(eight) <= Double(window) * Self.prefixBudgetFraction,
                "8 tools cost \(eight) of \(window) tokens — over the \(Self.prefixBudgetFraction) prefix budget"
            )
        }

        @Test("a ninth control tool would be the one that does not fit, and is why queue_tracks is out")
        @available(macOS 26.4, iOS 26.4, *)
        func theDroppedToolIsAccountedFor() throws {
            guard case .available = AssistantAvailabilityProbe.current(intelligenceEnabled: true) else { return }
            let (granted, _) = try ToolboxFixtures.makeControllableToolbox(ToolboxFixtures.makeLibrary())
            let published = Set(granted.tools(profile: .onDevice).map(\.name))
            #expect(!published.contains("queue_tracks"))
            #expect(granted.tool(named: "queue_tracks") != nil, "it is registered — just not on-device")
            #expect(Set(granted.tools(profile: .external).map(\.name)).contains("queue_tracks"))
        }

        /// Tokens the session's FIXED prefix occupies: the instructions entry, which
        /// is where the SDK injects every published tool definition.
        @available(macOS 26.4, iOS 26.4, *)
        private static func prefixTokens(_ toolbox: LibraryToolbox) async throws -> Int {
            let tools = LibraryChatTools.onDevice(toolbox, counts: LibraryChatToolCounts())
            // Mirrors `LibraryChatSession.init` EXACTLY, control line included: the
            // grant adds a sentence as well as three definitions, and a measurement
            // that priced only the definitions would under-report what ships.
            let instructions = LibraryChatInstructions.text(
                locale: Locale(identifier: "en_US"),
                profile: .onDevice,
                canControlPlayback: toolbox.context.playback != nil
            )
            let session = LanguageModelSession(model: .default, tools: tools) { instructions }
            return try await SystemLanguageModel.default.tokenCount(for: Array(session.transcript))
        }
    }
#endif
