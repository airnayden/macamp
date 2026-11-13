// OpenAIConnectorTests — transport shape, model listing, and the failure taxonomy.
//
// The strict-mode schema proof lives next door in `OpenAIStrictSchemaTests`, which
// is the acceptance criterion this todo exists for. This file covers everything
// else: what goes out on the wire, what comes back, and that EVERY documented
// failure path lands on the exact `ConnectorFailure` case rather than a generic
// error.
//
// Zero network: every answer is scripted through `FakeHTTPTransport`.
import AIConnectorKit
import Foundation
import Testing

@Suite("OpenAIConnectorTests")
struct OpenAIConnectorTests {
    /// Mirrors `OpenAIConnector.maxDiagnosticBodyLength`, which is internal to the
    /// kit and therefore invisible from this target.
    private static let expectedDiagnosticBodyLength = 512

    private func connector(
        _ transport: FakeHTTPTransport,
        apiKey: @escaping @Sendable () async throws -> String = { "sk-test-macamp" },
        onRefusal: (@Sendable (String) -> Void)? = nil
    ) -> OpenAIConnector {
        OpenAIConnector(apiKey: apiKey, transport: transport, onRefusal: onRefusal)
    }

    // MARK: - Identity

    @Test("The connector identity is stable and its auth rides the Authorization header")
    func connectorIdentityIsStable() {
        let subject = connector(FakeHTTPTransport())

        #expect(subject.id == "openai")
        #expect(subject.displayName == "OpenAI")
        #expect(subject.authDescriptor == .apiKey(header: "Authorization"))
        #expect(subject.authDescriptor.requiresStoredSecret)
        #expect(OpenAIConnector.structuredOutputName == "playlist_query")
    }

    // MARK: - listModels

    @Test("Models come straight from the fixture, blank ids dropped, capabilities unstated")
    func modelsAreParsedFromTheFixture() async throws {
        let response = try openAIFixtureResponse("openai-models.json")
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        let models = try await connector(transport).listModels()

        #expect(models.map(\.id) == ["gpt-4o", "gpt-4o-mini", "text-embedding-3-small"])
        // displayName falls back to the id — OpenAI offers no friendlier name.
        #expect(models.map(\.displayName) == ["gpt-4o", "gpt-4o-mini", "text-embedding-3-small"])
        // Hoisted out of `#expect`: the macro decomposes a trailing function call
        // into a `rethrows` helper, which a key-path argument cannot satisfy.
        let capabilitiesAreUnstated = models.allSatisfy(\.capabilities.isEmpty)
        #expect(capabilitiesAreUnstated)
    }

    @Test("The models call is a GET to /v1/models carrying a bearer token and no body")
    func theModelsRequestIsABearerGet() async throws {
        let response = try openAIFixtureResponse("openai-models.json")
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        _ = try await connector(transport).listModels()

        let recorded = try #require(await transport.recordedRequests.first)
        #expect(recorded.url?.absoluteString == "\(OpenAIConnector.baseURLString)/models")
        #expect(recorded.httpMethod == "GET")
        #expect(recorded.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-macamp")
        #expect(recorded.httpBody == nil)
    }

    // MARK: - Completions

    @Test("structuredCompletion returns the message content as raw bytes")
    func structuredCompletionReturnsRawContentBytes() async throws {
        let response = try openAIFixtureResponse("openai-chat-structured.json")
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        let data = try await connector(transport).structuredCompletion(
            schema: JSONSchemaObject(properties: [.init(name: "genres", schema: .array(of: .string()))]),
            instructions: "Return JSON.",
            prompt: "dreamy shoegaze from the nineties",
            model: "gpt-4o"
        )

        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = try #require(decoded)
        #expect(payload["genres"] as? [String] == ["Shoegaze"])
        #expect(payload["targetCount"] as? Int == 25)
        #expect(payload["yearUpperBound"] is NSNull)
    }

    @Test("A plain completion sends no response_format and trims the prose it returns")
    func plainCompletionSendsNoResponseFormat() async throws {
        let prose = #"""
        {"choices":[{"index":0,"message":{"role":"assistant","content":"\n  Midnight Shoegaze  \n","refusal":null}}]}
        """#
        let transport = FakeHTTPTransport(scripts: [
            .success(HTTPResponse(statusCode: 200, body: Data(prose.utf8))),
        ])

        let name = try await connector(transport).completion(
            instructions: "Name this playlist.",
            prompt: "dreamy shoegaze",
            model: "gpt-4o"
        )

        #expect(name == "Midnight Shoegaze")
        let recorded = try #require(await transport.recordedRequests.first)
        #expect(recorded.url?.absoluteString == "\(OpenAIConnector.baseURLString)/chat/completions")
        #expect(recorded.httpMethod == "POST")
        #expect(recorded.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try openAIRecordedJSONBody(recorded)
        #expect(body["response_format"] == nil)
        #expect(body["model"] as? String == "gpt-4o")
    }

    @Test("Instructions and prompt become a system message and a user message, in that order")
    func messagesCarryInstructionsThenPrompt() async throws {
        let response = try openAIFixtureResponse("openai-chat-structured.json")
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        _ = try await connector(transport).structuredCompletion(
            schema: JSONSchemaObject(properties: []),
            instructions: "Return JSON.",
            prompt: "dreamy shoegaze",
            model: "gpt-4o"
        )

        let recorded = try #require(await transport.recordedRequests.first)
        let body = try openAIRecordedJSONBody(recorded)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == "Return JSON.")
        #expect(messages.last?["role"] as? String == "user")
        #expect(messages.last?["content"] as? String == "dreamy shoegaze")
    }

    // MARK: - Refusal

    @Test("A refusal maps to .malformedResponse and surfaces its text through the sink")
    func refusalMapsToMalformedResponse() async throws {
        let response = try openAIFixtureResponse("openai-chat-refusal.json")
        let transport = FakeHTTPTransport(scripts: [.success(response)])
        let recorder = OpenAIRefusalRecorder()
        let subject = connector(transport, onRefusal: { recorder.record($0) })

        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await subject.structuredCompletion(
                schema: JSONSchemaObject(properties: []),
                instructions: "Return JSON.",
                prompt: "something the model declines",
                model: "gpt-4o"
            )
        }

        #expect(recorder.messages == ["I'm sorry, I can't help with that request."])
    }

    @Test("A refusal is still .malformedResponse when no sink is wired")
    func refusalWithoutASinkStillFails() async throws {
        let response = try openAIFixtureResponse("openai-chat-refusal.json")
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await connector(transport).completion(
                instructions: "Name this playlist.",
                prompt: "something the model declines",
                model: "gpt-4o"
            )
        }
    }

    // MARK: - Failure mapping

    @Test("401 maps to .authExpired")
    func unauthorizedMapsToAuthExpired() async throws {
        let response = try openAIFixtureResponse("openai-error-401.json", statusCode: 401)
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await connector(transport).listModels()
        }
    }

    @Test("403 joins 401 — a revoked key cannot be retried into working")
    func forbiddenMapsToAuthExpired() async throws {
        let response = try openAIFixtureResponse("openai-error-401.json", statusCode: 403)
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await connector(transport).listModels()
        }
    }

    @Test("429 maps to .rateLimited, parsing Retry-After seconds")
    func rateLimitedParsesRetryAfterSeconds() async throws {
        let response = try openAIFixtureResponse(
            "openai-error-429.json",
            statusCode: 429,
            headers: ["Retry-After": "3"]
        )
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 3)) {
            _ = try await connector(transport).listModels()
        }
    }

    @Test("429 falls back to OpenAI's retry-after-ms header")
    func rateLimitedFallsBackToMilliseconds() async throws {
        let response = try openAIFixtureResponse(
            "openai-error-429.json",
            statusCode: 429,
            headers: ["retry-after-ms": "1500"]
        )
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 1.5)) {
            _ = try await connector(transport).listModels()
        }
    }

    @Test("429 with no retry hint yields a nil interval rather than a guess")
    func rateLimitedWithoutAHintYieldsNil() async throws {
        let response = try openAIFixtureResponse("openai-error-429.json", statusCode: 429)
        let transport = FakeHTTPTransport(scripts: [.success(response)])

        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: nil)) {
            _ = try await connector(transport).listModels()
        }
    }

    @Test("5xx maps to .httpStatus with a truncated body and no request material")
    func serverErrorMapsToHttpStatusWithTruncatedBody() async throws {
        let overlong = String(repeating: "e", count: 2000)
        let transport = FakeHTTPTransport(scripts: [
            .success(HTTPResponse(statusCode: 503, body: Data(overlong.utf8))),
        ])
        let subject = connector(transport)

        do {
            _ = try await subject.listModels()
            Issue.record("expected the 503 to fail")
        } catch let failure as ConnectorFailure {
            guard case let .httpStatus(code, body, providerMessage) = failure else {
                Issue.record("expected .httpStatus, got \(failure)")
                return
            }
            #expect(code == 503)
            #expect(body?.count == Self.expectedDiagnosticBodyLength)
            #expect(body?.contains("sk-test-macamp") == false)
            #expect(providerMessage == nil, "A non-JSON body carries no `error.message` to show")
        }
    }

    @Test("Non-JSON on a 200 maps to .malformedResponse")
    func nonJSONBodyMapsToMalformedResponse() async {
        let transport = FakeHTTPTransport(scripts: [
            .success(HTTPResponse(statusCode: 200, body: Data("<html>nope</html>".utf8))),
        ])

        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await connector(transport).listModels()
        }
    }

    @Test("A 200 with no choices maps to .malformedResponse")
    func emptyChoicesMapToMalformedResponse() async {
        let transport = FakeHTTPTransport(scripts: [
            .success(HTTPResponse(statusCode: 200, body: Data(#"{"choices":[]}"#.utf8))),
        ])

        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await connector(transport).completion(
                instructions: "Name it.",
                prompt: "shoegaze",
                model: "gpt-4o"
            )
        }
    }

    @Test("Transport failures pass through unchanged — never relabelled")
    func transportFailuresPassThrough() async {
        let refused = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused)
        let transport = FakeHTTPTransport(scripts: [.failure(refused)])

        await #expect(throws: refused) {
            _ = try await connector(transport).listModels()
        }
    }

    // MARK: - Unconfigured

    @Test("A blank key is .unconfigured and performs NO transport call")
    func blankKeyIsUnconfiguredAndSilent() async throws {
        let transport = FakeHTTPTransport()

        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await connector(transport, apiKey: { "   " }).listModels()
        }

        #expect(await transport.recordedRequests.isEmpty)
    }

    @Test("A throwing key provider is .unconfigured and performs NO transport call")
    func throwingKeyProviderIsUnconfiguredAndSilent() async throws {
        struct NoStoredSecret: Error {}
        let transport = FakeHTTPTransport()

        await #expect(throws: ConnectorFailure.unconfigured) {
            _ = try await connector(transport, apiKey: { throw NoStoredSecret() }).listModels()
        }

        #expect(await transport.recordedRequests.isEmpty)
    }

    @Test("A key provider that throws a taxonomy failure keeps that exact case")
    func keyProviderTaxonomyFailurePassesThrough() async {
        let transport = FakeHTTPTransport()

        await #expect(throws: ConnectorFailure.authExpired) {
            _ = try await connector(transport, apiKey: { throw ConnectorFailure.authExpired }).listModels()
        }
    }
}
