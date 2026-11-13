// LibraryTool — one callable capability, in the shape all three adapters project
// from.
//
// ── THE NAME IS A WIRE FORMAT ─────────────────────────────────────────────────
//
// ``name`` is used VERBATIM as a FoundationModels tool name, as a provider
// function name, and as an MCP tool name. It is snake_case because that is the
// only spelling all three accept without rewriting, and it is STABLE: renaming one
// breaks a saved provider conversation and an external MCP client at the same
// time. Add a tool; do not rename one.
//
// ── THE DESCRIPTION IS BILLED PER TURN ────────────────────────────────────────
//
// FoundationModels injects every published tool's description into the same 4096
// token window the conversation lives in, on EVERY turn. One short sentence,
// stating what the tool returns rather than how it works. The argument
// documentation belongs in ``parametersSchema``, which is billed once.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// One typed, callable capability over the library.
public struct LibraryTool: Sendable {
    /// Stable snake_case identifier. See the file header — this is a wire format.
    public let name: String
    /// One short sentence. See the file header — this is billed every turn.
    public let description: String
    /// A JSON-Schema object describing the arguments. Built with ``ToolSchema``.
    public let parametersSchema: ToolboxJSON
    /// Runs the tool. Reads only — the one write-adjacent tool FILES a proposal
    /// through ``ToolboxProposalFiling`` and still writes nothing itself.
    public let execute: @Sendable (ToolArguments) async throws -> ToolResult

    public init(
        name: String,
        description: String,
        parametersSchema: ToolboxJSON,
        execute: @escaping @Sendable (ToolArguments) async throws -> ToolResult
    ) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.execute = execute
    }
}

/// Why a tool call failed for a reason that is not about its arguments.
public enum LibraryToolError: Error, Sendable, Equatable {
    /// No tool is registered under that name.
    case unknownTool(name: String)
    /// A row the call named does not exist, or is not visible to this profile.
    case notFound(what: String, id: Int64)
    /// A read failed. Nothing was written — the whole tool layer is read-only
    /// except for ``ToolboxProposalFiling``, which files rather than writes.
    case readFailed(reason: String)
    /// Filing a proposal failed.
    case proposalFailed(reason: String)

    /// The sentence handed back to the model. Same audience and same rationale as
    /// ``ToolArgumentError/message``.
    public var message: String {
        switch self {
        case let .unknownTool(name):
            "There is no tool named \"\(name)\"."
        case let .notFound(what, id):
            "No \(what) with id \(id) is available to this listener."
        case let .readFailed(reason):
            "The library could not be read: \(reason)"
        case let .proposalFailed(reason):
            "The proposal could not be filed: \(reason)"
        }
    }
}
