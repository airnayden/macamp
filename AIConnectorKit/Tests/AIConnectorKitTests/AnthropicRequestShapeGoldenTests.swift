// AnthropicRequestShapeGoldenTests — the API-KEY route's body, pinned byte for byte.
//
// ── WHY A GOLDEN, WHEN `AnthropicConnectorTests` ALREADY ASSERTS THE FIELDS ───
//
// Those suites assert the fields anyone REMEMBERED to assert. This one asserts
// the whole body, so a change nobody thought to test — a field added, dropped,
// renamed, or re-shaped — fails here instead of at a provider that answers a
// malformed request with a 400.
//
// The pressure is real and specific: ``ClaudeSubscriptionConnector`` wraps this
// exact connector and rewrites what it forwards (identity-only `system`, framing
// relocated into the prose). Every one of those edits is a chance to "fix" the
// shared base instead of the wrapper, and the API-key route has no OAuth edge to
// fingerprint it — it wants the plain-string `system` it has always sent. This
// file is the tripwire.
//
// ── WHAT IS NORMALIZED, AND WHAT IS NOT ──────────────────────────────────────
//
// `max_tokens` keeps its KEY and loses its VALUE. The field is required (omitting
// it is a 400) so its presence stays pinned, but the number is a tuning knob that
// legitimately moves — pinning it here would make an unrelated ceiling raise look
// like a wire-shape regression, and a test that cries wolf gets deleted.
//
// NOTHING ELSE is normalized. Keys are re-serialised sorted so the comparison is
// independent of which encoder produced the body, and the goldens below are the
// bytes the connector actually sent.
import AIConnectorKit
import Foundation
import Testing

@Suite("AnthropicRequestShapeGoldenTests")
struct AnthropicRequestShapeGoldenTests {
    private static let model = "claude-sonnet-4-20250514"
    private static let instructions = "Answer with a playlist query."
    private static let prompt = "something upbeat"

    private static let schema = JSONSchemaObject(properties: [
        .init(name: "genres", schema: .array(of: .string())),
    ])

    // MARK: - Goldens

    private static let completionGolden = """
    {"max_tokens":0,"messages":[{"content":"something upbeat","role":"user"}],\
    "model":"claude-sonnet-4-20250514","system":"Answer with a playlist query."}
    """

    private static let structuredGolden = """
    {"max_tokens":0,"messages":[{"content":"something upbeat","role":"user"}],\
    "model":"claude-sonnet-4-20250514","system":"Answer with a playlist query.",\
    "tool_choice":{"name":"emit_playlist_query","type":"tool"},\
    "tools":[{"description":"Emit the requested structured result. Call this tool exactly once and fill every \
    property of its schema.","input_schema":{"additionalProperties":false,"properties":{"genres":{"items":\
    {"type":"string"},"type":"array"}},"required":["genres"],"type":"object"},"name":"emit_playlist_query"}]}
    """

    private static let chatTurnGolden = """
    {"max_tokens":0,"messages":[{"content":"make me a shoegaze mix","role":"user"}],\
    "model":"claude-sonnet-4-20250514","system":"Answer with a playlist query.",\
    "tool_choice":{"type":"auto"},"tools":[{"description":"A fixture tool.","input_schema":\
    {"additionalProperties":false,"properties":{"query":{"type":"string"}},"required":["query"],\
    "type":"object"},"name":"search_tracks","strict":true}]}
    """

    // MARK: - The three entry points

    @Test("completion sends the pinned body — plain-string system, instructions in it")
    func completionBodyMatchesTheGolden() async throws {
        let transport = Self.transport(#"{"content":[{"type":"text","text":"Late Night Jazz"}]}"#)
        let connector = Self.connector(transport)

        _ = try await connector.completion(
            instructions: Self.instructions,
            prompt: Self.prompt,
            model: Self.model
        )

        #expect(try await Self.normalizedBody(transport) == Self.completionGolden)
    }

    @Test("structuredCompletion sends the pinned body — forced tool, schema verbatim")
    func structuredCompletionBodyMatchesTheGolden() async throws {
        let transport = Self.transport("""
        {"content":[{"type":"tool_use","name":"\(AnthropicConnector.structuredToolName)",\
        "input":{"genres":["Jazz"]}}]}
        """)
        let connector = Self.connector(transport)

        _ = try await connector.structuredCompletion(
            schema: Self.schema,
            instructions: Self.instructions,
            prompt: Self.prompt,
            model: Self.model
        )

        #expect(try await Self.normalizedBody(transport) == Self.structuredGolden)
    }

    @Test("chatTurn sends the pinned body — the wrapper's rewrites never reach this route")
    func chatTurnBodyMatchesTheGolden() async throws {
        let transport = Self.transport(#"{"content":[{"type":"text","text":"Here are five."}]}"#)
        let connector = Self.connector(transport)
        let tool = AITool(
            name: "search_tracks",
            description: "A fixture tool.",
            parametersSchema: .object([
                "type": .string("object"),
                "properties": .object(["query": .object(["type": .string("string")])]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ])
        ) { _ in AIToolOutput(text: "unused") }

        _ = try await connector.chatTurn(ToolTurnRequest(
            instructions: Self.instructions,
            messages: [.user("make me a shoegaze mix")],
            tools: [tool],
            model: Self.model
        ))

        #expect(try await Self.normalizedBody(transport) == Self.chatTurnGolden)
    }

    // MARK: - The normalization itself

    @Test("The golden's one normalization is the max_tokens VALUE — the KEY stays pinned")
    func onlyTheMaxTokensValueIsNormalized() async throws {
        let transport = Self.transport(#"{"content":[{"type":"text","text":"Late Night Jazz"}]}"#)
        let connector = Self.connector(transport)

        _ = try await connector.completion(
            instructions: Self.instructions,
            prompt: Self.prompt,
            model: Self.model
        )

        // Omitting `max_tokens` is a 400, so a golden that normalised the key away
        // would green-light the one change this file exists to catch.
        #expect(Self.completionGolden.contains("\"max_tokens\":"))
        let raw = try await Self.rawBody(transport)
        #expect(raw.contains("\"max_tokens\":\(AnthropicConnector.maxTokensForCompletion)"))
    }
}

// MARK: - Scaffolding

private extension AnthropicRequestShapeGoldenTests {
    static func connector(_ transport: FakeHTTPTransport) -> AnthropicConnector {
        AnthropicConnector(auth: .apiKey(provider: { "sk-ant-api03-test-key" }), transport: transport)
    }

    static func transport(_ responseBody: String) -> FakeHTTPTransport {
        FakeHTTPTransport(scripts: [.success(HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(responseBody.utf8)
        ))])
    }

    static func rawBody(_ transport: FakeHTTPTransport) async throws -> String {
        let recorded = await transport.recordedRequests
        let body = try #require(recorded.first?.httpBody)
        return try #require(String(bytes: body, encoding: .utf8))
    }

    /// The recorded body, re-serialised with sorted keys and the `max_tokens`
    /// VALUE replaced by zero. See this file's header for what that buys.
    static func normalizedBody(_ transport: FakeHTTPTransport) async throws -> String {
        let recorded = await transport.recordedRequests
        let data = try #require(recorded.first?.httpBody)
        var json = try #require((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        // Overwritten only when PRESENT: assigning unconditionally would invent the
        // required field for a body that omitted it, and the golden would go green
        // on the exact 400 this file exists to catch.
        if json["max_tokens"] != nil {
            json["max_tokens"] = 0
        }
        let normalized = try JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try #require(String(bytes: normalized, encoding: .utf8))
    }
}
