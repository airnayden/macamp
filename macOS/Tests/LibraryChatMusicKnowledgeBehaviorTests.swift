// LibraryChatMusicKnowledgeBehaviorTests — the permission is not just PRINTED, it
// reaches the provider and the answer it allows reaches the listener unchanged.
//
// ── WHY THIS SUITE CANNOT LIVE BESIDE THE STRING TEST ────────────────────────
//
// `LibraryChatInstructionsTests` (PlayerCore/AssistantTests) asserts the BYTES of
// the instructions, which is the cheap half of the claim. The other half — that a
// general music question survives the whole turn — needs a `ToolCallingConnector`,
// and that protocol is declared in `AIConnectorKit`, which PlayerCore must never
// import (the dependency direction is bridge -> PlayerCore). So the behavioural
// claim is made HERE, where both sides are visible, following the precedent of
// `LibraryChatCompositionTests` and `LibraryChatCorrectiveWiringTests`.
//
// ── WHAT "NON-REFUSAL" MEANS AS AN ASSERTION ─────────────────────────────────
//
// The model is scripted, so asserting that IT did not refuse would be asserting
// something this test wrote. What is actually under test is everything between the
// provider and the transcript: the answer arrives byte-for-byte, on one assistant
// row, with no failure and no corrective second turn — the three ways a real answer
// gets lost or doubled on its way to the listener. The instructions the connector
// was HANDED are asserted separately, and that is the claim about permission.
//
// Nothing here reaches a provider, the Keychain or the network: the connector
// answers from memory and the tool list is empty.
import AIConnectorBridge
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing
import ViewModels

@Suite("Library chat music knowledge", .serialized)
@MainActor
struct LibraryChatMusicKnowledgeBehaviorTests {
    /// A question about no library at all — the one that was measured being refused
    /// while the grounding rule was still unscoped.
    private static let question = "what is the greatest rock song of all time"
    private static let answer = "Most critics land on Stairway to Heaven, with Like a Rolling Stone close behind."

    @Test("a general music question is answered, and the answer reaches the transcript unchanged")
    func aGeneralMusicQuestionReachesTheTranscript() async {
        let recorder = InstructionRecorder()
        let model = Self.chat(recorder: recorder, musicKnowledgeEnabled: true)

        await model.send(Self.question)

        let assistant = model.messages.filter { $0.role == .assistant }
        #expect(assistant.count == 1)
        #expect(assistant.first?.text == Self.answer)
        #expect(assistant.first?.failure == nil)
        #expect(model.messages.first?.text == Self.question)
        // One round trip: a question with no playlist stem in it must not draw the
        // corrective follow-up, which would put a second answer under the first.
        #expect(await recorder.count == 1)
    }

    @Test("the instructions the provider was actually handed carry the permission and its verification rule")
    func theProviderIsToldItMayUseWhatItKnows() async {
        let recorder = InstructionRecorder()
        let model = Self.chat(recorder: recorder, musicKnowledgeEnabled: true)

        await model.send(Self.question)

        let seen = await recorder.instructions.first ?? ""
        #expect(seen.contains("your own knowledge of music"))
        #expect(seen.contains("verify candidates with match_tracks before proposing"))
        #expect(seen.contains("General music questions"))
        // The prohibition it has to coexist with, scoped so it still holds.
        #expect(seen.contains("never invent a title or an artist as being in this library"))
    }

    @Test("with the setting off the same conversation carries no permission at all")
    func theGateIsOffByDefault() async {
        let recorder = InstructionRecorder()
        let model = Self.chat(recorder: recorder, musicKnowledgeEnabled: false)

        await model.send(Self.question)

        let seen = await recorder.instructions.first ?? ""
        #expect(!seen.isEmpty)
        #expect(!seen.contains("your own knowledge of music"))
        #expect(!seen.contains("General music questions"))
        #expect(seen.contains("never invent a title or an artist as being in this library"))
    }

    // MARK: Helpers

    /// The real connector tier — real `ConnectorChatEngine`, real tool loop, real
    /// conversation actor — with only the MODEL scripted, which is the same
    /// substitution point `ScriptedChatUITestSeam` uses.
    private static func chat(recorder: InstructionRecorder, musicKnowledgeEnabled: Bool) -> LibraryChatViewModel {
        let engine = ConnectorChatEngine(
            connector: ScriptedProseConnector(answer: answer, recorder: recorder),
            model: "scripted",
            tools: [],
            instructions: LibraryChatInstructions.text(
                locale: Locale(identifier: "en_US"),
                profile: .cloud,
                musicKnowledgeEnabled: musicKnowledgeEnabled
            )
        )
        let conversation = ConnectorChatConversation(engine: engine, isActive: { true })
        return LibraryChatViewModel(makeEngine: { .success(conversation.engineValue) })
    }
}

// MARK: - The scripted provider

/// What the connector was asked, in order.
///
/// An `actor` because `chatTurn` is called off the main actor by the tool loop and
/// the recorded value is read back from a `@MainActor` test.
private actor InstructionRecorder {
    private(set) var instructions: [String] = []

    var count: Int {
        instructions.count
    }

    func record(_ instructions: String) {
        self.instructions.append(instructions)
    }
}

/// A connector that answers one round of prose and records its framing.
///
/// No tool calls, so the loop terminates on the first round — this suite is about
/// the answer reaching the transcript, not about tool execution, which
/// `LibraryChatCompositionTests` already covers.
private struct ScriptedProseConnector: ToolCallingConnector {
    let answer: String
    let recorder: InstructionRecorder

    var id: String {
        "macamp.tests.musicKnowledge"
    }

    var displayName: String {
        "Scripted"
    }

    var authDescriptor: AuthDescriptor {
        .subscription
    }

    func listModels() async throws -> [ModelInfo] {
        []
    }

    func structuredCompletion(
        schema _: JSONSchemaObject,
        instructions _: String,
        prompt _: String,
        model _: String
    ) async throws -> Data {
        Data("{}".utf8)
    }

    func completion(instructions _: String, prompt _: String, model _: String) async throws -> String {
        ""
    }

    func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
        await recorder.record(request.instructions)
        return ToolTurnResponse(text: answer)
    }
}
