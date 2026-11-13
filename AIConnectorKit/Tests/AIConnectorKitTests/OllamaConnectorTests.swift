// OllamaConnectorTests — the happy paths, driven entirely off checked-in fixtures.
//
// Every byte the connector "receives" here came from a file recorded against the
// documented Ollama wire format, and every byte it sends is inspected on
// `FakeHTTPTransport.recordedRequests`. No socket is opened: the kit's suites make
// ZERO live requests, so a developer with no Ollama installed — and CI, which has
// none either — runs exactly the same assertions.
//
// The recorded-request assertions are the important half. A connector that parsed
// a response correctly but sent the schema under the wrong key, or streamed by
// accident, would still return plausible-looking bytes from a fixture; only
// looking at what went OUT can catch that.
import AIConnectorKit
import Foundation
import Testing

/// The checked-in `/api/tags` and `/api/chat` payloads, plus the canonicalisation
/// helpers the recorded-request assertions compare through.
enum OllamaFixture {
    static let tags = "ollama-tags.json"
    static let chatStructured = "ollama-chat-structured.json"
    static let chatError = "ollama-chat-error.json"

    enum FixtureError: Error {
        /// A recorded request carried no body, or a body that was not a JSON object.
        case notAJSONObject
    }

    /// A stand-in for the bridge's real query schema: one enum-constrained string
    /// array and one nullable integer, which between them exercise every encoding
    /// branch a provider request body can hit (`enum`, `items`, a
    /// `["integer", "null"]` type union, `required`, `additionalProperties`).
    static let querySchema = JSONSchemaObject(
        properties: [
            JSONSchemaObject.Property(
                name: "genres",
                schema: .array(of: .string(allowedValues: ["Rock", "Blues", "Jazz"]))
            ),
            JSONSchemaObject.Property(name: "decade", schema: .integer(isNullable: true)),
        ],
        description: "A listening request, parsed."
    )

    /// Fixtures load through `#filePath` rather than `Bundle.module` — the test
    /// target declares no resources, and this is how every `Fixtures/` directory in
    /// the repo's PlayerCore suites is already read.
    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    static func response(_ name: String, statusCode: Int = 200) throws -> HTTPResponse {
        try HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: data(name)
        )
    }

    /// A transport scripted to answer exactly one request with a fixture.
    static func transport(_ name: String, statusCode: Int = 200) throws -> FakeHTTPTransport {
        let scripted = try response(name, statusCode: statusCode)
        return FakeHTTPTransport(scripts: [.success(scripted)])
    }

    /// Re-serialises a parsed JSON value with sorted keys.
    ///
    /// Comparing two documents through this rather than comparing raw bytes keeps
    /// the assertion about CONTENT: `JSONEncoder` and `JSONSerialization` are free
    /// to disagree on whitespace and escaping, and neither difference would mean
    /// the schema was sent wrong.
    static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func canonical(_ schema: JSONSchemaObject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(schema)
        return try canonical(JSONSerialization.jsonObject(with: encoded))
    }

    /// The JSON object a recorded request carried.
    static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody,
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            throw FixtureError.notAJSONObject
        }
        return root
    }
}

@Suite("OllamaConnectorTests")
struct OllamaConnectorTests {
    private static let model = "llama3.2:latest"
    private static let framing = "You classify listening requests."
    private static let ask = "seventies rock"

    @Test("Models are parsed from the /api/tags fixture, newest field name and legacy alike")
    func modelsAreParsedFromTheTagsFixture() async throws {
        let transport = try OllamaFixture.transport(OllamaFixture.tags)
        let connector = OllamaConnector(transport: transport)

        let models = try await connector.listModels()

        // The third fixture entry carries `model` but no `name`, so this also pins
        // the fallback a newer server would need.
        #expect(models.map(\.id) == ["llama3.2:latest", "qwen2.5:7b", "mistral-small:24b"])
        // Ollama offers no friendlier name than the tag, so `displayName` collapses
        // onto `id` — the selector shows exactly what gets sent back.
        #expect(models.map(\.displayName) == models.map(\.id))
        #expect(models.allSatisfy { $0.capabilities == [.chat, .structuredOutput] })
    }

    @Test("Listing models is a plain GET against the configured host")
    func listingModelsIsAPlainGet() async throws {
        let transport = try OllamaFixture.transport(OllamaFixture.tags)
        let connector = OllamaConnector(transport: transport)

        _ = try await connector.listModels()

        let recorded = await transport.recordedRequests
        let request = try #require(recorded.first)
        #expect(recorded.count == 1)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/tags")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
    }

    @Test("Endpoint paths are appended, so a reverse-proxy prefix survives")
    func endpointPathsAreAppendedToTheHost() async throws {
        let host = try #require(URL(string: "https://box.lan/ollama"))
        let transport = try OllamaFixture.transport(OllamaFixture.tags)
        let connector = OllamaConnector(host: host, transport: transport)

        _ = try await connector.listModels()

        let recorded = await transport.recordedRequests
        #expect(recorded.first?.url?.absoluteString == "https://box.lan/ollama/api/tags")
    }

    @Test("A structured call sends the schema as `format` and unwraps the content")
    func structuredCallSendsTheSchemaAsFormat() async throws {
        let transport = try OllamaFixture.transport(OllamaFixture.chatStructured)
        let connector = OllamaConnector(transport: transport)

        let data = try await connector.structuredCompletion(
            schema: OllamaFixture.querySchema,
            instructions: Self.framing,
            prompt: Self.ask,
            model: Self.model
        )

        // The returned bytes are the assistant message content itself — Ollama
        // needs no envelope unwrapping the way the other two providers do.
        let parsed = try JSONSerialization.jsonObject(with: data)
        let document = try #require(parsed as? [String: Any])
        #expect(document["genres"] as? [String] == ["Rock", "Blues"])
        #expect(document["decade"] as? Int == 1970)

        let recorded = await transport.recordedRequests
        let request = try #require(recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try OllamaFixture.requestBody(request)
        #expect(body["model"] as? String == Self.model)
        // Streaming would answer with newline-delimited objects, which is not one
        // JSON document — the flag is correctness, not a performance preference.
        #expect(body["stream"] as? Bool == false)

        let format = try #require(body["format"] as? [String: Any])
        let sent = try OllamaFixture.canonical(format)
        let expected = try OllamaFixture.canonical(OllamaFixture.querySchema)
        #expect(sent == expected)
    }

    @Test("Instructions become a system turn ahead of the user turn")
    func instructionsBecomeASystemTurn() async throws {
        let transport = try OllamaFixture.transport(OllamaFixture.chatStructured)
        let connector = OllamaConnector(transport: transport)

        _ = try await connector.completion(instructions: Self.framing, prompt: Self.ask, model: Self.model)

        let recorded = await transport.recordedRequests
        let request = try #require(recorded.first)
        let body = try OllamaFixture.requestBody(request)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages.first?["content"] as? String == Self.framing)
        #expect(messages.last?["role"] as? String == "user")
        #expect(messages.last?["content"] as? String == Self.ask)
    }

    @Test("Blank instructions send no system turn at all")
    func blankInstructionsSendNoSystemTurn() async throws {
        let transport = try OllamaFixture.transport(OllamaFixture.chatStructured)
        let connector = OllamaConnector(transport: transport)

        _ = try await connector.completion(instructions: "   ", prompt: Self.ask, model: Self.model)

        let recorded = await transport.recordedRequests
        let request = try #require(recorded.first)
        let body = try OllamaFixture.requestBody(request)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages.first?["role"] as? String == "user")
    }

    @Test("A plain completion omits `format` entirely and returns the raw content")
    func plainCompletionOmitsFormat() async throws {
        let transport = try OllamaFixture.transport(OllamaFixture.chatStructured)
        let connector = OllamaConnector(transport: transport)

        let text = try await connector.completion(
            instructions: Self.framing,
            prompt: Self.ask,
            model: Self.model
        )

        #expect(text.contains("\"decade\": 1970"))

        let recorded = await transport.recordedRequests
        let request = try #require(recorded.first)
        let body = try OllamaFixture.requestBody(request)
        // The optional is encoded with `encodeIfPresent`, so an unconstrained turn
        // must leave the key off the wire rather than send `"format": null`.
        #expect(body.keys.contains("format") == false)
        #expect(body["stream"] as? Bool == false)
    }

    @Test("The connector's identity and auth descriptor are the shipped constants")
    func identityAndAuthDescriptorAreTheShippedConstants() throws {
        let host = try #require(URL(string: "https://box.lan/ollama"))
        let connector = OllamaConnector(host: host, transport: FakeHTTPTransport())

        #expect(connector.id == "ollama")
        #expect(connector.displayName == "Ollama")
        // The descriptor answers "what should the host field be pre-filled with",
        // which is the stock address — never the value already configured.
        #expect(connector.authDescriptor == .none(defaultHost: OllamaConnector.defaultHost))
        #expect(connector.authDescriptor.requiresStoredSecret == false)
        #expect(OllamaConnector.defaultHost.absoluteString == "http://127.0.0.1:11434")
    }
}
