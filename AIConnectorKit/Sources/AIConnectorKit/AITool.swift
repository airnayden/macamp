// AITool — one callable capability, in the shape every provider adapter projects
// from.
//
// ── `execute` RETURNS TEXT AND NEVER THROWS ──────────────────────────────────
//
// A tool result is CONVERSATION, not control flow. Every one of the four wire
// formats carries it as a string the model reads and reacts to, and a refusal the
// model can read ("There is no track with id 42 available to this listener.") is
// strictly more useful than an exception that ends the turn. PlayerCore's
// `LibraryToolbox.run(_:arguments:profile:)` already renders refusals as
// sentences for exactly this reason, so the bridge adapter is a straight
// pass-through and this signature is what makes that possible.
//
// The text is also assumed to be ALREADY CAPPED by whoever built the tool —
// `ToolProfile.cloud` caps a rendered result at 8 KB. ``ToolLoopEngine`` still
// clamps at 16 KB as a backstop, because "the caller capped it" is a claim about
// a caller this kit does not own.
//
// ── THE SCHEMA IS OPAQUE JSON, ON PURPOSE ────────────────────────────────────
//
// See ``AIJSONValue``'s header: a schema builder would silently drop the
// `minimum` / `maximum` / `maxItems` bounds PlayerCore's tools document.
//
// ── `execute` ANSWERS WITH A VALUE, NOT A BARE STRING ────────────────────────
//
// A shell wants to say "Searched your library — 12 results" beside a lookup, and
// the only honest source of that 12 is the tool that built the rows. Recovering
// it from the returned TEXT would mean parsing prose a tool is free to rephrase,
// so ``AIToolOutput`` carries the text and the count side by side. The count is
// `Int?` because "how many results" is not a question every tool answer can be
// asked, and it never reaches the wire: a provider is handed
// ``ToolCallOutcome/text`` exactly as before.
//
// ── AND THE SAME ARGUMENT, ONE TYPE LARGER, FOR THE ROWS ────────────────────
//
// A shell that can say "12 results" wants to DRAW those twelve, and reading the
// titles back out of the text is the same parse this file already refuses for the
// count. So ``AIToolOutput`` carries the structured half too. It travels exactly
// as far as the count does — into ``ChatEvent/toolResult(name:text:resultCount:rows:suggestions:)``
// and no further — because a provider is still handed ``ToolCallOutcome/text``
// and nothing else.
//
// ``AIToolRow`` and ``AIToolSuggestion`` MIRROR PlayerCore's `AssistantChatRow` /
// `AssistantChatSuggestion` rather than reusing them: this kit is liftable into
// another app and knows nothing about tracks, so it cannot import the module
// those live in. `AIConnectorBridge` — the one product that may see both — does
// the copy, and builds them with PlayerCore's own discriminator so the two tiers
// cannot disagree about what a track row is.
import Foundation

/// One track a tool answered with, as a shell draws it.
///
/// Every field is optional because a tool's payload fields are: a row with no
/// title still has an id to act on.
public struct AIToolRow: Sendable, Equatable, Hashable {
    /// The library row's id — the handle a shell offers actions against.
    public let trackId: Int64?
    public let title: String?
    public let artist: String?

    public init(trackId: Int64? = nil, title: String? = nil, artist: String? = nil) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
    }
}

/// Something a tool was asked for and could not find.
///
/// `title` is non-optional: a miss with nothing to name is not worth a line.
public struct AIToolSuggestion: Sendable, Equatable, Hashable {
    public let title: String
    public let artist: String?

    public init(title: String, artist: String? = nil) {
        self.title = title
        self.artist = artist
    }
}

/// What one ``AITool/execute`` produced.
public struct AIToolOutput: Sendable, Equatable, Hashable {
    /// How many rows or suggestions one answer may carry to a shell.
    ///
    /// A BACKSTOP over PlayerCore's own cap of the same size, in the same spirit
    /// as ``ToolLoopEngine/maxToolResultCharacters``: "the caller bounded it" is a
    /// claim about a caller this kit does not own.
    public static let maxRows = 50

    /// The text handed back to the model.
    public let text: String
    /// How many results the answer is about, or `nil` when it is not list-shaped.
    public let resultCount: Int?
    /// The answer's tracks, for a shell that draws a list rather than prose.
    public let rows: [AIToolRow]
    /// What the tool was asked for and could not find.
    public let suggestions: [AIToolSuggestion]

    public init(
        text: String,
        resultCount: Int? = nil,
        rows: [AIToolRow] = [],
        suggestions: [AIToolSuggestion] = []
    ) {
        self.text = text
        self.resultCount = resultCount
        self.rows = rows
        self.suggestions = suggestions
    }
}

/// One tool a model may call during a conversation turn.
public struct AITool: Sendable {
    /// The name sent to the provider and matched against the call it emits.
    ///
    /// A WIRE FORMAT: PlayerCore's toolbox uses stable snake_case names that are
    /// shared verbatim with the FoundationModels tier and an external MCP client,
    /// so renaming one breaks a saved conversation and an MCP client at once.
    public let name: String

    /// One short sentence, stating what the tool RETURNS.
    ///
    /// Billed on every round: all four providers re-send the whole tool list with
    /// each request, so a paragraph here is a paragraph of context spent per hop.
    public let description: String

    /// A JSON-Schema object describing the arguments, carried verbatim.
    public let parametersSchema: AIJSONValue

    /// Runs the tool over the raw JSON argument text the provider emitted.
    ///
    /// - Parameter argumentsJSON: The model's arguments as a JSON object string.
    ///   May be `""` or `"{}"` for an argument-less call — two of the four wire
    ///   formats emit the empty string rather than an empty object.
    /// - Returns: The text handed back to the model, plus the optional result
    ///   count a shell may render. Never throws; see the file header.
    public let execute: @Sendable (String) async -> AIToolOutput

    public init(
        name: String,
        description: String,
        parametersSchema: AIJSONValue,
        execute: @escaping @Sendable (String) async -> AIToolOutput
    ) {
        self.name = name
        self.description = description
        self.parametersSchema = parametersSchema
        self.execute = execute
    }
}

public extension Sequence<AITool> {
    /// The first tool registered under `name`, or `nil`.
    func tool(named name: String) -> AITool? {
        first { $0.name == name }
    }
}

// MARK: - Strict-mode eligibility

/// Whether a schema may be published with the provider's `strict` flag set.
///
/// ── WHY THIS IS A PREDICATE AND NOT A CONSTANT `true` ────────────────────────
///
/// Anthropic (`tools[].strict`, a 2026 addition), OpenAI
/// (`tools[].function.strict`) and the ChatGPT Responses backend
/// (`tools[].strict`) all offer guaranteed schema conformance, and all three
/// impose the SAME two conditions on the document to grant it: every object must
/// carry `additionalProperties: false`, and `required` must name EVERY declared
/// property — optionality expressed by omission is rejected, and must instead be
/// a nullable type union. ``JSONSchemaObject`` encodes that by default, which is
/// why the one-shot `structuredCompletion` path can hardcode `strict: true`.
///
/// A TOOL schema is not built here. PlayerCore's ten library tools are built by
/// `ToolSchema.object(_:required:)`, which lists only the genuinely required
/// arguments — `search_tracks` requires `query` and leaves `limit` out. Sending
/// `strict: true` beside such a document is a guaranteed 400 on most of those
/// tools, so the flag is DERIVED from the document rather than asserted over
/// it. `strict: false` is the documented default on all three providers, so the
/// ineligible branch is ordinary non-strict function calling, not a degraded mode.
///
/// Sources read 2026-08-28: OpenAI function calling / structured outputs guide;
/// Anthropic tool-use overview.
public enum AIToolStrictness {
    /// JSON-Schema keys this check reads. Spelled once so a typo is a compile
    /// error at one site rather than a silently-permissive answer at four.
    enum Key {
        static let type = "type"
        static let properties = "properties"
        static let required = "required"
        static let additionalProperties = "additionalProperties"
        static let items = "items"
        static let objectType = "object"
    }

    /// Whether `schema` satisfies every provider's strict-mode conditions,
    /// checked recursively through nested objects and array items.
    ///
    /// A non-object schema (a bare string, a number) is trivially eligible: the
    /// conditions are statements about objects.
    public static func isEligible(_ schema: AIJSONValue) -> Bool {
        guard let object = schema.objectValue else { return true }
        if declaresObjectType(object), isStrictObject(object) == false { return false }
        if let items = object[Key.items], isEligible(items) == false { return false }
        for nested in (object[Key.properties]?.objectValue ?? [:]).values where isEligible(nested) == false {
            return false
        }
        return true
    }

    /// Whether this node claims to be an object, in either the bare (`"object"`)
    /// or nullable-union (`["object", "null"]`) spelling.
    private static func declaresObjectType(_ object: [String: AIJSONValue]) -> Bool {
        guard let type = object[Key.type] else { return object[Key.properties] != nil }
        if type.stringValue == Key.objectType { return true }
        return type.arrayValue?.contains { $0.stringValue == Key.objectType } ?? false
    }

    /// The two conditions, on ONE object node.
    private static func isStrictObject(_ object: [String: AIJSONValue]) -> Bool {
        guard object[Key.additionalProperties]?.boolValue == false else { return false }
        let declared = Set((object[Key.properties]?.objectValue ?? [:]).keys)
        let required = Set((object[Key.required]?.arrayValue ?? []).compactMap(\.stringValue))
        return declared.isSubset(of: required)
    }
}
