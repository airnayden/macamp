// AIProviderConnectorTests — the seam is implementable, and its transport injects.
//
// A stub conformer stands in for the real Ollama / Anthropic / OpenAI connectors
// that land in later todos. It exists to prove three things about the CONTRACT
// rather than about any provider: the protocol is satisfiable by a plain `Sendable`
// struct over an injected ``HTTPTransport``, every request provably flows through
// that injected seam, and transport failures reach the caller as the taxonomy
// without re-mapping.
import AIConnectorKit
import Foundation
import Testing

/// The smallest thing that can honestly claim to be a connector.
private struct StubConnector: AIProviderConnector {
    let id = "stub"
    let displayName = "Stub"
    let authDescriptor: AuthDescriptor
    let transport: any HTTPTransport
    let endpoint: URL

    func listModels() async throws -> [ModelInfo] {
        var request = URLRequest(url: endpoint.appending(path: "models"))
        request.httpMethod = "GET"
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw ConnectorFailure.httpStatus(response.statusCode, body: nil, providerMessage: nil)
        }
        guard let names = try? JSONDecoder().decode([String].self, from: response.body) else {
            throw ConnectorFailure.malformedResponse
        }
        return names.map { ModelInfo(id: $0, capabilities: [.chat]) }
    }

    func structuredCompletion(
        schema: JSONSchemaObject,
        instructions _: String,
        prompt: String,
        model: String
    ) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var request = URLRequest(url: endpoint.appending(path: "chat"))
        request.httpMethod = "POST"
        request.setValue(model, forHTTPHeaderField: "x-model")
        request.setValue(prompt, forHTTPHeaderField: "x-prompt")
        request.httpBody = try encoder.encode(schema)
        return try await transport.send(request).body
    }

    func completion(instructions _: String, prompt: String, model _: String) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "chat"))
        request.httpMethod = "POST"
        request.httpBody = Data(prompt.utf8)
        let response = try await transport.send(request)
        guard let text = String(data: response.body, encoding: .utf8) else {
            throw ConnectorFailure.malformedResponse
        }
        return text
    }
}

@Suite("AIProviderConnectorTests")
struct AIProviderConnectorTests {
    private static let endpoint = "https://connector.invalid/v1/"

    private func makeConnector(
        transport: FakeHTTPTransport,
        authDescriptor: AuthDescriptor = .apiKey(header: "x-api-key")
    ) throws -> StubConnector {
        let url = try #require(URL(string: Self.endpoint))
        return StubConnector(authDescriptor: authDescriptor, transport: transport, endpoint: url)
    }

    @Test("listModels routes through the injected transport and parses the response")
    func listModelsRoutesThroughTheInjectedTransport() async throws {
        let body = Data(#"["llama3.2:latest","qwen2.5:7b"]"#.utf8)
        let transport = FakeHTTPTransport(scripts: [.success(HTTPResponse(statusCode: 200, body: body))])
        let connector = try makeConnector(transport: transport)

        let models = try await connector.listModels()

        #expect(models.map(\.id) == ["llama3.2:latest", "qwen2.5:7b"])
        #expect(models.first?.displayName == "llama3.2:latest")
        #expect(models.first?.capabilities == [.chat])

        let recorded = await transport.recordedRequests
        #expect(recorded.count == 1)
        #expect(recorded.first?.url?.absoluteString == "https://connector.invalid/v1/models")
        #expect(recorded.first?.httpMethod == "GET")
    }

    @Test("structuredCompletion sends the schema as the request body")
    func structuredCompletionSendsTheSchemaAsTheRequestBody() async throws {
        let transport = FakeHTTPTransport(scripts: [
            .success(HTTPResponse(statusCode: 200, body: Data(#"{"genres":["Jazz"]}"#.utf8))),
        ])
        let connector = try makeConnector(transport: transport)
        let schema = JSONSchemaObject(properties: [
            .init(name: "genres", schema: .array(of: .string())),
        ])

        let payload = try await connector.structuredCompletion(
            schema: schema,
            instructions: "be terse",
            prompt: "some jazz",
            model: "llama3.2:latest"
        )

        #expect(String(data: payload, encoding: .utf8) == #"{"genres":["Jazz"]}"#)

        let recorded = await transport.recordedRequests
        let sent = try #require(recorded.first?.httpBody)
        #expect(String(data: sent, encoding: .utf8) == """
        {"additionalProperties":false,\
        "properties":{"genres":{"items":{"type":"string"},"type":"array"}},\
        "required":["genres"],\
        "type":"object"}
        """)
        #expect(recorded.first?.value(forHTTPHeaderField: "x-model") == "llama3.2:latest")
    }

    @Test("completion returns provider prose verbatim")
    func completionReturnsProviderProseVerbatim() async throws {
        let transport = FakeHTTPTransport(scripts: [
            .success(HTTPResponse(statusCode: 200, body: Data("Late Night Jazz".utf8))),
        ])
        let connector = try makeConnector(transport: transport)

        let text = try await connector.completion(instructions: "name it", prompt: "jazz", model: "stub-1")

        #expect(text == "Late Night Jazz")
    }

    @Test("A transport failure reaches the caller as the taxonomy, unchanged")
    func transportFailureReachesTheCallerUnchanged() async throws {
        let refused = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused)
        let transport = FakeHTTPTransport(scripts: [.failure(refused)])
        let connector = try makeConnector(transport: transport)

        await #expect(throws: refused) {
            _ = try await connector.listModels()
        }
    }

    @Test("A non-2xx status becomes .httpStatus, and unparseable JSON .malformedResponse")
    func statusAndParseFailuresMapOntoTheTaxonomy() async throws {
        let failing = FakeHTTPTransport(scripts: [.success(HTTPResponse(statusCode: 500))])
        await #expect(throws: ConnectorFailure.httpStatus(500, body: nil, providerMessage: nil)) {
            _ = try await makeConnector(transport: failing).listModels()
        }

        let garbage = FakeHTTPTransport(scripts: [
            .success(HTTPResponse(statusCode: 200, body: Data("not json".utf8))),
        ])
        await #expect(throws: ConnectorFailure.malformedResponse) {
            _ = try await makeConnector(transport: garbage).listModels()
        }
    }

    @Test("The subscription auth case is spelled subscription, never oauth")
    func subscriptionAuthCaseIsNamedForTheLinkGate() throws {
        // Swift emits case names into binary reflection metadata even in Release, so
        // an `oauth`-spelled case would put that string into any binary linking the
        // core target alone — which carries no OAuth logic. See `AuthDescriptor`'s
        // header: load-bearing for embedders, not cosmetic.
        #expect(AuthDescriptor.subscription.requiresStoredSecret)
        #expect(AuthDescriptor.apiKey(header: "x-api-key").requiresStoredSecret)

        let host = try #require(URL(string: "http://127.0.0.1:11434"))
        #expect(AuthDescriptor.none(defaultHost: host).requiresStoredSecret == false)

        let connector = try makeConnector(transport: FakeHTTPTransport(), authDescriptor: .subscription)
        #expect(connector.authDescriptor == .subscription)
    }

    @Test("A model with no provider-supplied name falls back to its id")
    func modelDisplayNameFallsBackToItsIdentifier() {
        #expect(ModelInfo(id: "gpt-4o").displayName == "gpt-4o")
        #expect(ModelInfo(id: "gpt-4o", displayName: "   ").displayName == "gpt-4o")
        #expect(ModelInfo(id: "gpt-4o", displayName: "  GPT-4o  ").displayName == "GPT-4o")
        #expect(ModelInfo(id: "gpt-4o").capabilities.isEmpty)
    }
}
