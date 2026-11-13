// LibraryToolAdapter — W1's `LibraryToolbox` projected into W2's ``AITool``.
//
// This is the ONLY place the two vocabularies meet, which is what keeps
// `AIConnectorKit` liftable into another app: the kit knows about tools with JSON
// schemas and text results, and knows nothing about tracks, profiles or
// `ToolProfile`. The whole adaptation is three lines of substance — copy the
// name, convert the schema, route `execute` at `run` — and everything else in
// this file exists to make those three lines exactly faithful.
//
// ── `.cloud` IS NOT A DEFAULT, IT IS THE TIER ────────────────────────────────
//
// `ToolProfile` changes two things and only two: WHICH tools are published, and
// HOW MUCH text a result may occupy. A connector is the `.cloud` tier by
// definition, so it publishes every library tool and caps each result at
// `ToolResultBudget.cloudCharacterLimit` (8 KB). The profile is threaded through
// as a parameter rather than hardcoded because the SAME adapter is what an
// in-process MCP server (W5, `.external`) would use, and a hardcoded `.cloud`
// would silently under-serve it by 8 KB per result.
//
// ── A MALFORMED ARGUMENT PAYLOAD IS ANSWERED, NOT THROWN ────────────────────
//
// ``AITool/execute`` cannot throw, and `LibraryToolbox.run(_:arguments:profile:)`
// cannot either — it renders every refusal as a sentence the model can correct
// against. The one gap between them is `ToolArguments.decode`, which runs BEFORE
// `run` is reachable and does throw. So this adapter catches it and renders the
// refusal through `ToolResult.message(_:).renderedText(profile:)` — the exact
// call `LibraryToolbox.run` makes for a `ToolArgumentError` it catches itself, so
// a model sees byte-identical text whichever side of the boundary rejected it.
//
// ── THE ROWS ARE PROJECTED, NEVER RE-DISCRIMINATED ──────────────────────────
//
// `ToolRunOutcome` carries the answer's structured rows beside its text, and the
// kit carries them onward as ``AIToolRow`` / ``AIToolSuggestion``. Deciding WHICH
// of those rows is a library track is not a decision this file gets to make: the
// payload is untyped `ToolboxJSON`, six of its seven shapes are not tracks, and a
// second copy of that rule would drift the first time a payload key was renamed —
// silently, because nothing would fail to compile. So both gates come from
// PlayerCore, and this file only copies the result across the type boundary.
//
// ── WHY A PROTOCOL SEAM OVER A CONCRETE `LibraryToolbox` ────────────────────
//
// `LibraryToolboxContext` requires a concrete `TrackRepository`, which requires a
// migrated GRDB database. Testing "does the adapter convert a schema faithfully
// and route at the right tier" through a database would test the database. The
// seam is the two methods the adapter actually calls, `LibraryToolbox` conforms
// to it for free, and a suite drives a hand-built `LibraryTool` array instead.
import AIConnectorKit
import Foundation
import Services

// MARK: - The seam

/// The part of `LibraryToolbox` an adapter needs: publish a tier's tools, and run
/// one of them.
///
/// The requirement is `runResult`, not `run`: an ``AITool`` now answers with an
/// ``AIToolOutput``, so the adapter needs the answer's `resultCount` and not just
/// its text. `run` remains available as an extension over it, which keeps every
/// existing caller — and every conformer's obligation — down to one method.
public protocol LibraryToolPublishing: Sendable {
    func tools(profile: ToolProfile) -> [LibraryTool]
    func runResult(_ name: String, arguments: ToolArguments, profile: ToolProfile) async -> ToolRunOutcome
}

public extension LibraryToolPublishing {
    func run(_ name: String, arguments: ToolArguments = ToolArguments(), profile: ToolProfile) async -> String {
        await runResult(name, arguments: arguments, profile: profile).text
    }
}

/// Free conformance — both requirements are already `LibraryToolbox`'s shipped
/// signatures. The default argument on `runResult`'s `arguments:` does not affect
/// the function type, so it satisfies the requirement unchanged.
extension LibraryToolbox: LibraryToolPublishing {}

// MARK: - Schema conversion

/// `ToolboxJSON` → ``AIJSONValue``, case for case.
///
/// Two structurally identical enums exist because the dependency runs
/// kit → PlayerCore and never the reverse: `LibraryToolbox` lives below that
/// boundary and cannot name a kit type, and the kit must not name a PlayerCore
/// one. The conversion is mechanical and total, with no case where a value could
/// change meaning — which is the property the bridge suites pin over every one
/// of the shipped schemas.
public enum ToolboxJSONBridge {
    public static func value(_ json: ToolboxJSON) -> AIJSONValue {
        switch json {
        case .null: .null
        case let .bool(value): .bool(value)
        case let .number(value): .number(value)
        case let .string(value): .string(value)
        case let .array(values): .array(values.map(value(_:)))
        case let .object(values): .object(values.mapValues(value(_:)))
        }
    }
}

// MARK: - The adapter

/// Projects a library toolbox into the kit's tool vocabulary.
public enum LibraryToolAdapter {
    /// Every tool `profile` publishes, ready for a ``ToolCallingConnector``.
    public static func aiTools(
        _ toolbox: some LibraryToolPublishing,
        profile: ToolProfile = .cloud
    ) -> [AITool] {
        toolbox.tools(profile: profile).map { aiTool($0, toolbox: toolbox, profile: profile) }
    }

    /// One tool, with its schema converted and its execution routed at `profile`.
    public static func aiTool(
        _ tool: LibraryTool,
        toolbox: some LibraryToolPublishing,
        profile: ToolProfile = .cloud
    ) -> AITool {
        AITool(
            name: tool.name,
            description: tool.description,
            parametersSchema: ToolboxJSONBridge.value(tool.parametersSchema),
            execute: { argumentsJSON in
                switch decodedArguments(argumentsJSON) {
                case let .success(arguments):
                    let outcome = await toolbox.runResult(tool.name, arguments: arguments, profile: profile)
                    return output(outcome, toolNamed: tool.name)
                case let .failure(error):
                    return AIToolOutput(text: ToolResult.message(error.message).renderedText(profile: profile))
                }
            }
        )
    }

    /// One toolbox answer, in the kit's vocabulary.
    ///
    /// Both gates come from PlayerCore and neither is restated here — see the
    /// file header, and `AssistantChatRow.swift`'s for why each is load-bearing:
    ///
    ///   ALLOW-LIST  ``AssistantChatRow/carriesRows(toolNamed:)``. A control
    ///               tool's playback entry is a strict SUBSET of a track payload,
    ///               so no shape predicate can exclude it — and the cloud tier
    ///               publishes all four control tools, so this gate does strictly
    ///               more work here than it does on-device.
    ///   SHAPE       ``ToolResultRow/trackRowProjection``, applied per row by the
    ///               ``AssistantChatRow/rows(from:)-([ToolResultRow])`` overload,
    ///               which also owns the fifty-row cap.
    static func output(_ outcome: ToolRunOutcome, toolNamed name: String) -> AIToolOutput {
        guard AssistantChatRow.carriesRows(toolNamed: name) else {
            return AIToolOutput(text: outcome.text, resultCount: outcome.resultCount)
        }
        return AIToolOutput(
            text: outcome.text,
            resultCount: outcome.resultCount,
            rows: AssistantChatRow.rows(from: outcome.rows).map { AIToolRow(
                trackId: $0.trackId,
                title: $0.title,
                artist: $0.artist
            ) },
            suggestions: AssistantChatRow.suggestions(from: outcome.rows).map { AIToolSuggestion(
                title: $0.title,
                artist: $0.artist
            ) }
        )
    }

    /// Decodes the model's argument text, treating blank as "no arguments".
    ///
    /// Two of the four wire formats emit `""` rather than `{}` for a call to a
    /// tool that declares no arguments — `list_genres` and `list_playlists` are
    /// both in that set — and rejecting it would refuse a perfectly correct call.
    static func decodedArguments(_ text: String) -> Result<ToolArguments, ToolArgumentError> {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .success(ToolArguments())
        }
        do {
            // Bound before wrapping: SwiftFormat's `hoistTry` would otherwise
            // rewrite this as `try .success(…)`, which reads as though building
            // the `Result` throws.
            let arguments = try ToolArguments.decode(text)
            return .success(arguments)
        } catch let error as ToolArgumentError {
            return .failure(error)
        } catch {
            return .failure(.malformedJSON(reason: "\(error)"))
        }
    }
}
