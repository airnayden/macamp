// Shared scaffolding for the tool-loop suites. ZERO live network: every wire
// suite scripts `FakeHTTPTransport` against inline provider bodies, and the
// engine suites drive ``FakeToolCallingConnector`` with no transport at all.
//
// The two schemas below are the whole reason ``AIToolStrictness`` exists.
// ``ToolFixture/strictSchema`` satisfies both strict-mode conditions
// (`additionalProperties: false`, every property in `required`);
// ``ToolFixture/looseSchema`` is shaped exactly like PlayerCore's real
// `search_tracks` — one required argument, one optional one left out of
// `required` — which is the shape that would be a 400 if `strict: true` were
// hardcoded.
import AIConnectorKit
import Foundation

// MARK: - Tools

struct ToolInvocation: Equatable {
    let name: String
    let argumentsJSON: String
}

enum ToolFixture {
    /// Eligible for `strict: true` on all three providers that offer it.
    static let strictSchema: AIJSONValue = .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])]),
        "required": .array([.string("query")]),
        "additionalProperties": .bool(false),
    ])

    /// `ToolSchema.object([query, limit], required: ["query"])` — the shape
    /// PlayerCore's `search_tracks` really publishes, `maximum` bound included.
    static let looseSchema: AIJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object(["type": .string("string")]),
            "limit": .object([
                "type": .string("integer"),
                "minimum": .int(1),
                "maximum": .int(200),
            ]),
        ]),
        "required": .array([.string("query")]),
        "additionalProperties": .bool(false),
    ])
}

/// Records every tool invocation and answers from a per-name script.
///
/// `@unchecked Sendable` over an `NSLock` rather than an actor because
/// ``AITool/execute`` is a `@Sendable` closure a suite also wants to read from
/// synchronously while asserting — the same trade-off `ScriptedRandomBytes`
/// makes in the OAuth target.
final class ToolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolInvocation] = []
    private var scripted: [String: [String]]
    private let fallback: String
    /// What each named tool reports as its ``AIToolOutput/resultCount``. A name
    /// absent from the table answers `nil`, which is the not-list-shaped case.
    private let resultCounts: [String: Int]
    /// The structured half each named tool answers with. Absent means none —
    /// every tool whose answer is not a library list.
    private let rows: [String: [AIToolRow]]
    private let suggestions: [String: [AIToolSuggestion]]

    init(
        _ scripted: [String: [String]] = [:],
        resultCounts: [String: Int] = [:],
        rows: [String: [AIToolRow]] = [:],
        suggestions: [String: [AIToolSuggestion]] = [:],
        fallback: String = "fixture tool result"
    ) {
        self.scripted = scripted
        self.fallback = fallback
        self.resultCounts = resultCounts
        self.rows = rows
        self.suggestions = suggestions
    }

    var invocations: [ToolInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func answer(for invocation: ToolInvocation) -> String {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(invocation)
        guard var queue = scripted[invocation.name], queue.isEmpty == false else { return fallback }
        let next = queue.removeFirst()
        scripted[invocation.name] = queue
        return next
    }

    func tool(
        _ name: String,
        description: String = "A fixture tool.",
        schema: AIJSONValue = ToolFixture.strictSchema
    ) -> AITool {
        AITool(name: name, description: description, parametersSchema: schema) { [self] argumentsJSON in
            AIToolOutput(
                text: answer(for: ToolInvocation(name: name, argumentsJSON: argumentsJSON)),
                resultCount: resultCounts[name],
                rows: rows[name] ?? [],
                suggestions: suggestions[name] ?? []
            )
        }
    }
}

// MARK: - Connector

/// A ``ToolCallingConnector`` with no transport, for suites about the LOOP
/// rather than about a wire format.
final class FakeToolCallingConnector: ToolCallingConnector, @unchecked Sendable {
    enum Script {
        /// Emit these calls and this much prose, then wait to be answered.
        case calls([ToolCall], text: String = "")
        /// Answer and end the turn.
        case text(String)
        case failure(ConnectorFailure)
        /// Park until cancelled — how the per-round deadline is proven.
        case never
    }

    let id = "fake-tool-connector"
    let displayName = "Fake"
    let authDescriptor = AuthDescriptor.none(defaultHost: OllamaConnector.defaultHost)

    private let lock = NSLock()
    private var pending: [Script]
    private let fallback: Script
    private var recorded: [ToolTurnRequest] = []

    init(_ pending: [Script] = [], fallback: Script = .text("done")) {
        self.pending = pending
        self.fallback = fallback
    }

    /// Every request the connector was handed, in order — the seam that proves
    /// the engine really carried the transcript and the outcomes forward.
    var recordedRequests: [ToolTurnRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
        let script = next(recording: request)
        switch script {
        case let .calls(calls, text):
            return ToolTurnResponse(
                text: text,
                toolCalls: calls,
                transcript: request.transcript.appending([.string("round-\(recordedRequests.count)")])
            )
        case let .text(text):
            return ToolTurnResponse(text: text, transcript: request.transcript)
        case let .failure(failure):
            throw failure
        case .never:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw ConnectorFailure.cancelled
            }
            throw ConnectorFailure.timeout
        }
    }

    private func next(recording request: ToolTurnRequest) -> Script {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return pending.isEmpty ? fallback : pending.removeFirst()
    }

    func listModels() async throws -> [ModelInfo] {
        throw ConnectorFailure.unconfigured
    }

    func structuredCompletion(
        schema _: JSONSchemaObject,
        instructions _: String,
        prompt _: String,
        model _: String
    ) async throws -> Data {
        throw ConnectorFailure.unconfigured
    }

    func completion(instructions _: String, prompt _: String, model _: String) async throws -> String {
        throw ConnectorFailure.unconfigured
    }
}

// MARK: - Body reading

/// The recorded request body at `index`, as a kit JSON value.
///
/// Reading it back through ``AIJSONValue`` rather than `JSONSerialization` is
/// deliberate: an assertion then fails if the body is not what the SAME decoder
/// the connectors use would read, which is the property that actually matters.
func recordedJSONBody(_ transport: FakeHTTPTransport, at index: Int) async -> AIJSONValue? {
    let requests = await transport.recordedRequests
    guard requests.indices.contains(index), let body = requests[index].httpBody else { return nil }
    return AIJSONValue.decoded(from: body)
}

func jsonResponse(_ text: String, statusCode: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
}
