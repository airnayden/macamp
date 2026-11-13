// AnthropicConnectorTests — the wire contract, proved against recorded requests.
//
// Every assertion here is either about what the connector SENDS (read back off
// `FakeHTTPTransport.recordedRequests`) or about how a captured provider payload
// is mapped. Nothing touches the network, and the four response fixtures are real
// Anthropic shapes rather than hand-minimised stand-ins — a fixture trimmed to
// only the fields the parser reads cannot catch a parser that reads the wrong one.
//
// The three fields Anthropic rejects a request for omitting (`max_tokens`,
// `tool_choice.name`, `anthropic-version`) each get a dedicated assertion, because
// each failure mode is a 400 at runtime and invisible at compile time.
import AIConnectorKit
import Foundation
import Testing

/// Loads a fixture next to this file.
///
/// `#filePath` rather than `Bundle.module`: the fixtures are test INPUT, not a
/// build product, and the repo's own package declares its `Fixtures` directories
/// the same way (root `Package.swift` — "loaded via #filePath, not Bundle.module").
private enum AnthropicFixture {
    static func data(_ name: String) throws -> Data {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
        return try Data(contentsOf: directory.appending(path: name))
    }

    static let models = "anthropic-models.json"
    static let toolUse = "anthropic-messages-tool-use.json"
    static let unauthorized = "anthropic-error-401.json"
    static let rateLimited = "anthropic-error-429.json"
}

@Suite("AnthropicConnectorTests")
struct AnthropicConnectorTests {
    private static let apiKey = "sk-ant-api03-test-key"
    private static let bearerToken = "sk-ant-oat01-test-token"
    private static let model = "claude-sonnet-4-20250514"
    private static let modelsURL = "https://api.anthropic.com/v1/models"
    private static let messagesURL = "https://api.anthropic.com/v1/messages"

    /// The schema every structured test forces the tool with.
    private static let schema = JSONSchemaObject(properties: [
        .init(name: "genres", schema: .array(of: .string())),
    ])

    private func makeConnector(
        transport: FakeHTTPTransport,
        auth: AnthropicAuth = .apiKey(provider: { AnthropicConnectorTests.apiKey })
    ) -> AnthropicConnector {
        AnthropicConnector(auth: auth, transport: transport)
    }

    private func makeTransport(fixture: String, statusCode: Int = 200, headers: [String: String] = [:]) throws
        -> FakeHTTPTransport
    {
        let body = try AnthropicFixture.data(fixture)
        let response = HTTPResponse(statusCode: statusCode, headers: headers, body: body)
        return FakeHTTPTransport(scripts: [.success(response)])
    }

    /// The recorded request's JSON body, as a dictionary.
    private func decodedBody(of request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
    }

    private func firstRequest(_ transport: FakeHTTPTransport) async throws -> URLRequest {
        let recorded = await transport.recordedRequests
        return try #require(recorded.first)
    }

    // MARK: - Credential headers

    @Test("listModels sends x-api-key plus anthropic-version, and parses the live list")
    func listModelsSendsTheApiKeyAndVersionHeaders() async throws {
        let transport = try makeTransport(fixture: AnthropicFixture.models)
        let connector = makeConnector(transport: transport)

        let models = try await connector.listModels()

        #expect(models.map(\.id) == [
            "claude-sonnet-4-20250514",
            "claude-opus-4-20250514",
            "claude-3-5-haiku-20241022",
            "claude-3-haiku-20240307",
        ])
        #expect(models.first?.displayName == "Claude Sonnet 4")
        // A missing and a blank `display_name` both fall back to the id.
        #expect(models[2].displayName == "claude-3-5-haiku-20241022")
        #expect(models[3].displayName == "claude-3-haiku-20240307")
        #expect(models.first?.capabilities == [.chat, .toolUse, .structuredOutput])

        let request = try await firstRequest(transport)
        #expect(request.url?.absoluteString == Self.modelsURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == Self.apiKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(connector.id == "anthropic")
        #expect(connector.authDescriptor == .apiKey(header: "x-api-key"))
    }

    @Test("Bearer mode swaps the header and reports subscription auth")
    func bearerModeSwapsTheHeaderAndReportsSubscriptionAuth() async throws {
        // Stands in for todo 18's OAuth engine: an async provider that mints a
        // token per call. The connector must never see the difference.
        let transport = try makeTransport(fixture: AnthropicFixture.models)
        let connector = makeConnector(
            transport: transport,
            auth: .bearer(provider: { AnthropicConnectorTests.bearerToken })
        )

        _ = try await connector.listModels()

        let request = try await firstRequest(transport)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.bearerToken)")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        // The mode is what the registry and the settings UI read off the connector.
        #expect(connector.authDescriptor == .subscription)
        #expect(AnthropicAuth.bearerHeaderField == "Authorization")
        #expect(AnthropicAuth.apiKeyHeaderField == "x-api-key")
    }

    // MARK: - Forced-tool request shape

    @Test("structuredCompletion forces the single named tool and passes the schema through")
    func structuredCompletionForcesTheNamedTool() async throws {
        let transport = try makeTransport(fixture: AnthropicFixture.toolUse)
        let connector = makeConnector(transport: transport)

        _ = try await connector.structuredCompletion(
            schema: Self.schema,
            instructions: "Be terse.",
            prompt: "some dreamy shoegaze",
            model: Self.model
        )

        let request = try await firstRequest(transport)
        #expect(request.url?.absoluteString == Self.messagesURL)
        #expect(request.httpMethod == "POST")
        let body = try decodedBody(of: request)

        let toolChoice = try #require(body["tool_choice"] as? [String: Any])
        #expect(toolChoice["type"] as? String == "tool")
        #expect(toolChoice["name"] as? String == "emit_playlist_query")
        #expect(AnthropicConnector.structuredToolName == "emit_playlist_query")

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools.first?["name"] as? String == "emit_playlist_query")
        let inputSchema = try #require(tools.first?["input_schema"] as? [String: Any])
        #expect(inputSchema["type"] as? String == "object")
        #expect(inputSchema["required"] as? [String] == ["genres"])
        #expect(inputSchema["additionalProperties"] as? Bool == false)
    }

    @Test("Every /v1/messages request carries max_tokens, in both shapes")
    func everyMessagesRequestCarriesMaxTokens() async throws {
        let structuredTransport = try makeTransport(fixture: AnthropicFixture.toolUse)
        _ = try await makeConnector(transport: structuredTransport).structuredCompletion(
            schema: Self.schema,
            instructions: "Be terse.",
            prompt: "some dreamy shoegaze",
            model: Self.model
        )
        let structured = try await decodedBody(of: firstRequest(structuredTransport))
        #expect(structured["max_tokens"] as? Int == AnthropicConnector.maxTokensForStructuredCompletion)
        #expect(structured["max_tokens"] as? Int == 4096)
        #expect(structured["model"] as? String == Self.model)
        #expect(structured["system"] as? String == "Be terse.")

        let proseTransport = try makeTransport(fixture: AnthropicFixture.toolUse)
        _ = try await makeConnector(transport: proseTransport).completion(
            instructions: "Name it.",
            prompt: "shoegaze set",
            model: Self.model
        )
        let prose = try await decodedBody(of: firstRequest(proseTransport))
        #expect(prose["max_tokens"] as? Int == AnthropicConnector.maxTokensForCompletion)
    }

    @Test("Plain completion omits tools, and blank instructions omit the system field")
    func plainCompletionOmitsToolsAndBlankInstructionsOmitSystem() async throws {
        let transport = try makeTransport(fixture: AnthropicFixture.toolUse)
        let connector = makeConnector(transport: transport)

        _ = try await connector.completion(instructions: "   \n ", prompt: "shoegaze set", model: Self.model)

        let body = try await decodedBody(of: firstRequest(transport))
        #expect(body.keys.contains("tools") == false)
        #expect(body.keys.contains("tool_choice") == false)
        // `system` is a TOP-LEVEL field, never a `role: "system"` message — and it
        // is omitted entirely rather than sent blank.
        #expect(body.keys.contains("system") == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
        #expect(messages.first?["content"] as? String == "shoegaze set")
    }

    // MARK: - Response extraction

    @Test("The tool_use block's input is the structured payload; text blocks are the prose")
    func responseExtractionPicksTheRightBlock() async throws {
        let structuredTransport = try makeTransport(fixture: AnthropicFixture.toolUse)
        let payload = try await makeConnector(transport: structuredTransport).structuredCompletion(
            schema: Self.schema,
            instructions: "Be terse.",
            prompt: "some dreamy shoegaze",
            model: Self.model
        )

        // Re-serialized `.sortedKeys`, so the bytes are stable across runs. The
        // leading `text` block in the fixture is skipped, not concatenated.
        #expect(String(data: payload, encoding: .utf8) == """
        {"genres":["Shoegaze"],"moodTags":["dreamy"],"seedArtists":[],\
        "targetCount":25,"yearLowerBound":1990,"yearUpperBound":null}
        """)

        // The same fixture through `completion` yields only the text block — the
        // tool_use block is skipped rather than stringified into the prose.
        let proseTransport = try makeTransport(fixture: AnthropicFixture.toolUse)
        let text = try await makeConnector(transport: proseTransport).completion(
            instructions: "Name it.",
            prompt: "shoegaze set",
            model: Self.model
        )
        #expect(text == "Here is the query.")
    }

    @Test("A usable status with an unusable payload is .malformedResponse, never a crash")
    func anUnusableResponseBecomesMalformedResponse() async throws {
        let garbage = FakeHTTPTransport(scripts: [.success(HTTPResponse(statusCode: 200, body: Data("<html>".utf8)))])
        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await makeConnector(transport: garbage).listModels()
        }

        // A 200 whose content holds no tool_use block at all: the model answered in
        // prose instead of calling the forced tool.
        let proseOnly = Data(#"{"content":[{"type":"text","text":"I can't help with that."}]}"#.utf8)
        let refusing = FakeHTTPTransport(scripts: [.success(HTTPResponse(statusCode: 200, body: proseOnly))])
        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await makeConnector(transport: refusing).structuredCompletion(
                schema: Self.schema,
                instructions: "Be terse.",
                prompt: "some dreamy shoegaze",
                model: Self.model
            )
        }
    }

    // MARK: - Failure mapping

    @Test("The four failure modes map onto the exact taxonomy case")
    func theFourFailureModesMapOntoTheExactTaxonomyCase() async throws {
        let unauthorized = try makeTransport(fixture: AnthropicFixture.unauthorized, statusCode: 401)
        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await makeConnector(transport: unauthorized).listModels()
        }

        let throttled = try makeTransport(
            fixture: AnthropicFixture.rateLimited,
            statusCode: 429,
            headers: ["retry-after": "30"]
        )
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 30)) {
            _ = try await makeConnector(transport: throttled).listModels()
        }

        let broken = FakeHTTPTransport(scripts: [
            .success(HTTPResponse(statusCode: 503, body: Data("upstream unavailable".utf8))),
        ])
        await #expect(throws: ConnectorFailure.httpStatus(503, body: "upstream unavailable", providerMessage: nil)) {
            _ = try await makeConnector(transport: broken).listModels()
        }

        let stalled = FakeHTTPTransport(scripts: [.neverRespond], simulatedRequestTimeout: 0.05)
        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await makeConnector(transport: stalled).listModels()
        }
    }

    @Test("retry-after is carried only when the provider sent parseable delta-seconds")
    func retryAfterIsParsedOnlyWhenTheProviderSentDeltaSeconds() async throws {
        // Absent header: the case still fires, with no advice attached.
        let bare = try makeTransport(fixture: AnthropicFixture.rateLimited, statusCode: 429)
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: nil)) {
            _ = try await makeConnector(transport: bare).listModels()
        }

        // Case-insensitive lookup, and a fractional value survives.
        let cased = try makeTransport(
            fixture: AnthropicFixture.rateLimited,
            statusCode: 429,
            headers: ["Retry-After": " 1.5 "]
        )
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 1.5)) {
            _ = try await makeConnector(transport: cased).listModels()
        }

        // The HTTP-date form and a negative value are both "nothing parseable".
        for value in ["Wed, 21 Oct 2015 07:28:00 GMT", "-5"] {
            let odd = try makeTransport(
                fixture: AnthropicFixture.rateLimited,
                statusCode: 429,
                headers: ["retry-after": value]
            )
            await #expect(throws: ConnectorFailure.rateLimited(retryAfter: nil)) {
                _ = try await makeConnector(transport: odd).listModels()
            }
        }
    }

    // MARK: - Credential failures

    @Test("A credential that cannot be produced never reaches the transport")
    func aCredentialThatCannotBeProducedNeverReachesTheTransport() async throws {
        let blank = FakeHTTPTransport()
        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await makeConnector(transport: blank, auth: .apiKey(provider: { "  " })).listModels()
        }
        #expect(await blank.recordedRequests.isEmpty)

        // A refreshing token source says `.authExpired` precisely, and that is
        // forwarded unchanged rather than flattened to `.unconfigured`.
        let expired = FakeHTTPTransport()
        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await makeConnector(
                transport: expired,
                auth: .bearer(provider: { throw ConnectorFailure.authExpired })
            ).listModels()
        }
        #expect(await expired.recordedRequests.isEmpty)

        // Anything else — a Keychain read that failed, say — is `.unconfigured`:
        // no call was made, and the credential could not be produced.
        let broken = FakeHTTPTransport()
        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await makeConnector(
                transport: broken,
                auth: .apiKey(provider: { throw SecretStoreError.notFound(service: "svc", account: "acct") })
            ).listModels()
        }
        #expect(await broken.recordedRequests.isEmpty)
    }
}
