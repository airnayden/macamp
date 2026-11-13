// MCPToolboxBridge — W1's `LibraryToolbox` projected onto MCP's `tools/list` and
// `tools/call`, at the `.external` tier and no other.
//
// This is the fourth projection of the same registry (W3 FoundationModels, W2
// provider function declarations, W4's shell, this), and it obeys the same two
// rules the others do:
//
//   * The TOOL NAMES ARE A WIRE FORMAT. They are read verbatim from
//     `tools(profile: .external)`; nothing here renames, filters or reorders.
//   * A REFUSAL IS NOT A PROTOCOL ERROR. `run` never throws and renders a bad
//     argument as the sentence `ToolArgumentError` already writes for a model to
//     correct itself against — so a refusal comes back as `.text` with
//     `isError: false`, which is what makes the retry cost one round-trip. Only
//     two things set `isError: true`: a tool this tier does not publish, and a
//     library that is not currently reachable. Neither is model-actionable.
//
// The `.external` caps (100 rows, 16 KB, 300 characters a row) are W1's, applied
// inside `run`. No filePath and no audio can appear here because none appears in
// `ToolboxRendering`, which is the only place a track becomes text — see W1 note 6
// and `LibraryToolboxPrivacyTests`.
import Foundation
import MCP
import Services

/// The live toolbox, read at CALL time.
///
/// A closure rather than a stored `LibraryToolbox` because the registry is rebuilt
/// on a profile switch: capturing one would leave an external client answering
/// against the profile that was active when it connected. Reading through the seam
/// means the switch is visible on the very next `tools/call`, never mid-result.
struct MCPToolboxSource {
    let currentToolbox: @Sendable () async -> LibraryToolbox?
}

enum MCPToolboxBridge {
    /// The tier an external process gets. Never `.cloud`, never `.onDevice`.
    static let profile: ToolProfile = .external

    /// The ONE tool in the registry that is not a read (W1 note 7). It files a
    /// proposal the listener still has to review in the app; everything else
    /// cannot reach a repository at all.
    static let proposalToolName = "propose_playlist"

    static func tools(_ toolbox: LibraryToolbox) -> [Tool] {
        toolbox.tools(profile: profile).map { tool in
            Tool(
                name: tool.name,
                description: tool.description,
                inputSchema: value(tool.parametersSchema),
                annotations: annotations(for: tool.name)
            )
        }
    }

    static func call(
        _ name: String,
        arguments: [String: Value]?,
        toolbox: LibraryToolbox?
    ) async -> CallTool.Result {
        guard let toolbox else { return failure(unreachableMessage) }
        let published = toolbox.tools(profile: profile)
        guard published.contains(where: { $0.name == name }) else {
            return failure(unknownToolMessage(name, published: published.map(\.name)))
        }
        let text = await toolbox.run(
            name,
            arguments: ToolArguments(arguments?.mapValues(json) ?? [:]),
            profile: profile
        )
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }
}

// MARK: - JSON

extension MCPToolboxBridge {
    /// `ToolboxJSON` -> the SDK's value. A whole `.number` becomes `.int` so a
    /// schema bound reads as `100` rather than `100.0` in the published schema —
    /// W1 keeps ONE number case precisely because JSON has one, and this is where
    /// the integer is recovered (W1 note 1).
    static func value(_ json: ToolboxJSON) -> Value {
        switch json {
        case .null: .null
        case let .bool(flag): .bool(flag)
        case let .number(number): exactInteger(number).map(Value.int) ?? .double(number)
        case let .string(text): .string(text)
        case let .array(items): .array(items.map(value))
        case let .object(members): .object(members.mapValues(value))
        }
    }

    /// The SDK's value -> `ToolboxJSON`.
    ///
    /// `.data` has no counterpart and becomes `.null`: no library tool takes
    /// binary, and inventing a base64 string would hand `ToolArguments` a value it
    /// would then refuse with a confusing type error instead of a missing one.
    static func json(_ value: Value) -> ToolboxJSON {
        switch value {
        case .null, .data: .null
        case let .bool(flag): .bool(flag)
        case let .int(number): .number(Double(number))
        case let .double(number): .number(number)
        case let .string(text): .string(text)
        case let .array(items): .array(items.map(json))
        case let .object(members): .object(members.mapValues(json))
        }
    }

    private static func exactInteger(_ number: Double) -> Int? {
        guard number.rounded() == number, number.magnitude < Double(Int.max) else { return nil }
        return Int(number)
    }
}

// MARK: - Refusals and hints

private extension MCPToolboxBridge {
    /// Model-facing protocol payload, deliberately English and NOT localized —
    /// W1 note 2. A shell that renders one of these to a person has a shell bug.
    static var unreachableMessage: String {
        "The music library is not available right now. Library access is switched off in MacAMP."
    }

    static func unknownToolMessage(_ name: String, published: [String]) -> String {
        "There is no tool named \(name). Available tools: \(published.joined(separator: ", "))."
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    /// Hints, not guarantees — the spec says so, and a client must not make a
    /// safety decision on them. They are still worth publishing: every tool but
    /// one is a pure read, and `openWorldHint` is false for all ten because this
    /// registry is offline by construction (W1 note 8).
    static func annotations(for name: String) -> Tool.Annotations {
        Tool.Annotations(
            readOnlyHint: name != proposalToolName,
            destructiveHint: false,
            idempotentHint: name != proposalToolName,
            openWorldHint: false
        )
    }
}
