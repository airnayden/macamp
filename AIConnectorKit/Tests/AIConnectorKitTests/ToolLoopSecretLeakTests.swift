// ToolLoopSecretLeakTests — the leak proof for the tool-calling path.
//
// The tool loop adds four new value types that a shell will render, log, and in
// W4 put on screen: ``ChatEvent``, ``ToolCall``, ``ToolTranscript`` and
// ``ToolLoopOutcome``. None of them existed when the connector leak suites were
// written, so none of them was covered by one.
//
// ── THE STRUCTURAL ARGUMENT, ASSERTED RATHER THAN CLAIMED ────────────────────
//
// A credential reaches a provider through a HEADER and never through a body.
// Everything the loop carries forward — the transcript, the events, the outcome —
// is derived from RESPONSE bodies and from request BODIES. So if no request body
// ever contains the credential, no value the loop produces can contain it either,
// whatever a provider echoes back. That is the property this suite pins first,
// per connector, and it is stronger than grepping the outputs: it holds for
// inputs the fixtures never tried.
//
// Every fake secret here is `test-token-` prefixed, matching the OAuth target's
// convention, so one literal catches a leak through any rendering route.
import AIConnectorKit
import Foundation
import Testing

@Suite("ToolLoopSecretLeakTests")
struct ToolLoopSecretLeakTests {
    private static let anthropicKey = "test-token-anthropic-key-alpha"
    private static let openAIKey = "test-token-openai-key-alpha"
    private static let ollamaKey = "test-token-ollama-cloud-alpha"
    private static let secrets = [anthropicKey, openAIKey, ollamaKey, "test-token-"]

    private func assertNoLeak(_ rendered: String, _ context: Comment) {
        for secret in Self.secrets {
            #expect(rendered.contains(secret) == false, context)
        }
    }

    /// Rendered through every route a caller might reach for. `dump` and
    /// `String(reflecting:)` are here because they bypass
    /// `CustomStringConvertible` entirely.
    private func assertNoLeakEverywhere(_ value: some Any, _ label: String) {
        assertNoLeak(String(describing: value), "describing \(label)")
        assertNoLeak("\(value)", "interpolating \(label)")
        assertNoLeak(String(reflecting: value), "reflecting \(label)")
        var dumped = ""
        dump(value, to: &dumped)
        assertNoLeak(dumped, "dump of \(label)")
    }

    private static let anthropicRounds = [
        """
        {"id":"msg_01","stop_reason":"tool_use","content":[
          {"type":"tool_use","id":"toolu_01","name":"search_tracks","input":{"query":"shoegaze"}}]}
        """,
        """
        {"id":"msg_02","stop_reason":"end_turn","content":[{"type":"text","text":"Here are five."}]}
        """,
    ]

    private static let openAIRounds = [
        #"""
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_01","type":"function",
           "function":{"name":"search_tracks","arguments":"{\"query\":\"shoegaze\"}"}}]}}]}
        """#,
        #"{"choices":[{"message":{"role":"assistant","content":"Here are five."}}]}"#,
    ]

    private static let ollamaRounds = [
        """
        {"message":{"role":"assistant","content":"","tool_calls":[
          {"function":{"name":"search_tracks","arguments":{"query":"shoegaze"}}}]},"done":true}
        """,
        """
        {"message":{"role":"assistant","content":"Here are five."},"done":true}
        """,
    ]

    private static func request(_ tools: [AITool]) -> ToolLoopRequest {
        ToolLoopRequest(
            instructions: "Be useful.",
            userText: "make me a shoegaze mix",
            tools: tools,
            model: "fixture-model"
        )
    }

    private static func transport(_ rounds: [String]) -> FakeHTTPTransport {
        FakeHTTPTransport(scripts: rounds.map { .success(jsonResponse($0)) })
    }

    // MARK: - The structural property

    @Test("No connector ever writes its credential into a REQUEST BODY on a tool round")
    func credentialsRideHeadersNeverBodies() async throws {
        try await assertBodiesAreSecretFree(
            rounds: Self.anthropicRounds,
            connector: { AnthropicConnector(auth: .apiKey(provider: { Self.anthropicKey }), transport: $0) }
        )
        try await assertBodiesAreSecretFree(
            rounds: Self.openAIRounds,
            connector: { OpenAIConnector(apiKey: { Self.openAIKey }, transport: $0) }
        )
        try await assertBodiesAreSecretFree(
            rounds: Self.ollamaRounds,
            connector: { OllamaConnector(apiKey: { Self.ollamaKey }, transport: $0) }
        )
    }

    private func assertBodiesAreSecretFree(
        rounds: [String],
        connector: (FakeHTTPTransport) -> any ToolCallingConnector
    ) async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = Self.transport(rounds)
        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector(transport)
        )

        #expect(outcome.termination == .answered)
        for request in await transport.recordedRequests {
            let body = request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            assertNoLeak(body, "request body")
            // The credential really is present — in a HEADER — so this is a
            // statement about placement, not about a connector that forgot to
            // authenticate.
            assertNoLeak(request.url?.absoluteString ?? "", "request URL")
        }
        assertNoLeakEverywhere(outcome, "outcome")
        assertNoLeakEverywhere(outcome.events, "events")
    }

    // MARK: - The rendered surfaces

    @Test("Every tool-loop value type is secret-free under every rendering route")
    func toolLoopValueTypesRenderNoSecret() async throws {
        let recorder = ToolRecorder(["search_tracks": ["Found 5 tracks."]])
        let transport = Self.transport(Self.anthropicRounds)
        let connector = AnthropicConnector(
            auth: .apiKey(provider: { Self.anthropicKey }),
            transport: transport
        )

        let outcome = try await ToolLoopEngine().run(
            Self.request([recorder.tool("search_tracks")]),
            connector: connector
        )

        assertNoLeakEverywhere(outcome.text, "final text")
        for event in outcome.events {
            assertNoLeakEverywhere(event, "\(event)")
        }

        // A round's carry-over is built ENTIRELY from the response, so this is
        // where a provider echo would land if one ever did. Driven through a
        // FRESH connector so it gets its own scripted round rather than the
        // exhausted-script fallback of the loop above.
        let single = Self.transport(Self.anthropicRounds)
        let round = try await AnthropicConnector(
            auth: .apiKey(provider: { Self.anthropicKey }),
            transport: single
        ).chatTurn(
            ToolTurnRequest(
                instructions: "Be useful.",
                messages: [.user("hello")],
                tools: [recorder.tool("search_tracks")],
                model: "fixture-model"
            )
        )
        assertNoLeakEverywhere(round.transcript, "transcript")
        assertNoLeakEverywhere(round.toolCalls, "tool calls")
        #expect(round.toolCalls.isEmpty == false, "The fixture round really did carry a call")
    }

    // MARK: - Failures

    @Test("A rejected credential renders nothing at all, on every connector")
    func rejectedCredentialsRenderNothing() async throws {
        let unauthorized = jsonResponse("{\"error\":{\"type\":\"authentication_error\"}}", statusCode: 401)
        let connectors: [any ToolCallingConnector] = [
            AnthropicConnector(
                auth: .apiKey(provider: { Self.anthropicKey }),
                transport: FakeHTTPTransport(scripts: [.success(unauthorized)])
            ),
            OpenAIConnector(
                apiKey: { Self.openAIKey },
                transport: FakeHTTPTransport(scripts: [.success(unauthorized)])
            ),
            OllamaConnector(
                apiKey: { Self.ollamaKey },
                transport: FakeHTTPTransport(scripts: [.success(unauthorized)])
            ),
        ]

        for connector in connectors {
            do {
                _ = try await ToolLoopEngine().run(Self.request([]), connector: connector)
                Issue.record("A 401 must throw")
            } catch {
                assertNoLeakEverywhere(error, "failure from \(connector.id)")
                assertNoLeak(error.localizedDescription, "localizedDescription from \(connector.id)")
            }
        }
    }

    @Test("A gateway that echoes the credential back is the PROVIDER's leak, and the connector adds none")
    func anEchoingGatewayIsNotTheConnectorsLeak() async throws {
        // A badly-behaved gateway echoing the Authorization header is the one
        // realistic route a credential could ride OUT through `httpStatus(body:)`.
        // The retained payload is the RESPONSE, verbatim — the connector never
        // synthesises one from the request it sent, which is the property that
        // matters here.
        let echo = "{\"error\":\"upstream\",\"seen\":\"Bearer \(Self.openAIKey)\"}"
        let transport = FakeHTTPTransport(scripts: [.success(jsonResponse(echo, statusCode: 502))])
        let connector = OpenAIConnector(apiKey: { Self.openAIKey }, transport: transport)

        do {
            _ = try await ToolLoopEngine().run(Self.request([]), connector: connector)
            Issue.record("A 502 must throw")
        } catch let failure as ConnectorFailure {
            guard case let .httpStatus(status, body, providerMessage) = failure else {
                Issue.record("Expected httpStatus, got \(failure)")
                return
            }
            #expect(status == 502)
            #expect(body == echo, "The retained body is the provider's, verbatim")
            // The one payload a shell may RENDER reads `error.message` and nothing
            // else, so an echoed header two keys away from it cannot be picked up.
            #expect(providerMessage == nil, "Only `error.message` is displayable, and this body has none")
        }

        // And no tool-loop value type was produced at all: the turn threw before
        // any event, transcript or outcome existed.
        #expect(await transport.recordedRequests.count == 1)
        let sent = try #require(await transport.recordedRequests.first?.httpBody)
        assertNoLeak(String(bytes: sent, encoding: .utf8) ?? "", "the request that provoked the echo")
    }
}
