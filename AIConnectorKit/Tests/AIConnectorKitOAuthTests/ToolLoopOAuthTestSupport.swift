// Tool-loop scaffolding for the OAuth target.
//
// A deliberate near-duplicate of `AIConnectorKitTests/ToolLoopTestSupport.swift`.
// SwiftPM test targets cannot import one another, and the alternative — promoting
// shared test scaffolding into a shipped library product — would put a "pretend
// the provider said this" switch inside the binary. The same trade-off already
// produced two transports (`FakeHTTPTransport` here vs `FakeTokenTransport`
// there); this file keeps the recorder on the same side of that line.
//
// Only the pieces the two OAuth suites actually need are copied.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation

struct ToolInvocation: Equatable {
    let name: String
    let argumentsJSON: String
}

enum ToolFixture {
    /// Eligible for `strict: true`: `additionalProperties: false`, and every
    /// property listed in `required`.
    static let strictSchema: AIJSONValue = .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])]),
        "required": .array([.string("query")]),
        "additionalProperties": .bool(false),
    ])

    /// The shape PlayerCore's real `search_tracks` publishes — an optional
    /// argument left out of `required`, which strict mode rejects.
    static let looseSchema: AIJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object(["type": .string("string")]),
            "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(200)]),
        ]),
        "required": .array([.string("query")]),
        "additionalProperties": .bool(false),
    ])
}

/// Records every tool invocation and answers from a per-name script.
final class ToolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ToolInvocation] = []
    private var scripted: [String: [String]]
    private let fallback: String

    init(_ scripted: [String: [String]] = [:], fallback: String = "fixture tool result") {
        self.scripted = scripted
        self.fallback = fallback
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
            AIToolOutput(text: answer(for: ToolInvocation(name: name, argumentsJSON: argumentsJSON)))
        }
    }
}

func toolLoopResponse(_ text: String, statusCode: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
}

/// The recorded request body at `index`, read back through the SAME decoder the
/// connectors use.
func recordedJSONBody(_ transport: FakeTokenTransport, at index: Int) async -> AIJSONValue? {
    guard let body = await transport.recordedBody(index) else { return nil }
    return AIJSONValue.decoded(from: Data(body.utf8))
}

/// The plain-string `content` of every prose message in recorded body `index`, in
/// wire order.
///
/// String-valued only, which drops the carried-over turns by construction: a
/// replayed assistant turn and a `tool_result` reply both carry an ARRAY of
/// blocks, so what survives is exactly the history-plus-current-turn prose an
/// instruction-relocation assertion is about.
func proseContents(_ transport: FakeTokenTransport, at index: Int) async -> [String]? {
    guard let messages = await recordedJSONBody(transport, at: index)?["messages"]?.arrayValue else { return nil }
    return messages.compactMap { $0["content"]?.stringValue }
}
