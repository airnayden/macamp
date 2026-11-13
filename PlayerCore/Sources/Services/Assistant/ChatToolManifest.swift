// ChatToolManifest — the drift guard between W1's published schema and W3's
// hand-written FoundationModels argument structs.
//
// ── WHY THE DUPLICATION EXISTS AT ALL ─────────────────────────────────────────
//
// ``LibraryTool/parametersSchema`` is a RUNTIME value — a `ToolboxJSON` document
// built by ``ToolSchema``. A FoundationModels `Tool`'s `parameters` is a
// `GenerationSchema` SYNTHESISED AT COMPILE TIME by the `@Generable` macro from a
// nested `Arguments` struct. There is no API that turns the former into the
// latter, so the five wrappers necessarily restate their arguments by hand. That
// restatement is the only place in this epic where one fact is written twice, and
// an edit to a W1 schema would otherwise desync it in complete silence: the model
// would be shown a `limit` the tool no longer reads, or would never be offered a
// `seed` the tool now accepts, and NOTHING would fail.
//
// ── SO THE GUARD IS TWO-SIDED, WITH NO THIRD COPY ─────────────────────────────
//
// ``published(_:)`` reads the toolbox's own `parametersSchema`.
// ``reflected(name:arguments:)`` reads the ACTUAL Swift stored properties of the
// wrapper's `@Generable` struct, through `Mirror` over a probe instance. Neither
// side is a hand-maintained list, so the assertion `published == reflected` cannot
// be satisfied by updating a manifest and forgetting the struct — there is no
// manifest to update. A W1 rename, a type change, or a required/optional flip
// fails `LibraryChatSchemaParityTests` on the next run.
//
// Both readers return `nil` rather than guessing on anything they do not
// recognise, so an unmappable schema node or an unsupported Swift property type is
// a LOUD failure (the test requires non-nil) instead of a silently skipped field.
//
// ── IN `Sources`, NOT IN THE TEST TARGET ──────────────────────────────────────
//
// Same reasoning as ``ToolResult/truncationSuffix(omitted:)``: the projection from
// a `ToolboxJSON` schema to a typed argument list is part of the contract three
// adapters share, and W5's MCP server will want to read it too. A copy living
// only in a test file would be a second definition that nothing checks.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// The argument shapes the tool layer publishes.
///
/// Exactly the four ``ToolSchema`` can emit. A REPO-INTERNAL enum, so every switch
/// over it is exhaustive with no `default:` — a fifth shape has to break the build
/// at the wrapper that would have to carry it.
public enum ChatArgumentKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case string
    case integer
    case number
    case integerArray
}

/// One declared argument of one tool.
public struct ChatToolArgument: Sendable, Equatable, Hashable, Comparable {
    /// The wire name, as it appears in both the JSON schema and the Swift struct.
    public let name: String
    public let kind: ChatArgumentKind
    /// `true` when the schema lists it in `required` — and, on the Swift side,
    /// when the property is NOT `Optional`. That correspondence is the point.
    public let isRequired: Bool

    public init(name: String, kind: ChatArgumentKind, isRequired: Bool) {
        self.name = name
        self.kind = kind
        self.isRequired = isRequired
    }

    /// Ordered by name, so two manifests compare regardless of declaration order.
    public static func < (lhs: ChatToolArgument, rhs: ChatToolArgument) -> Bool {
        lhs.name < rhs.name
    }
}

/// One tool's name and complete argument list, name-sorted.
public struct ChatToolManifest: Sendable, Equatable {
    public let name: String
    /// Always sorted by ``ChatToolArgument/name``. Declaration order carries no
    /// meaning on either side — the JSON schema's `properties` is an unordered
    /// object and a Swift struct's property order is a formatting choice — so
    /// sorting here is what makes equality mean "the same arguments".
    public let arguments: [ChatToolArgument]

    public init(name: String, arguments: [ChatToolArgument]) {
        self.name = name
        self.arguments = arguments.sorted()
    }
}

// MARK: - Reading the published JSON schema

public extension ChatToolManifest {
    /// The manifest `tool` publishes, or `nil` if its schema is not an object
    /// schema this projection understands.
    static func published(_ tool: LibraryTool) -> ChatToolManifest? {
        guard let root = tool.parametersSchema.objectValue,
              let properties = root["properties"]?.objectValue
        else { return nil }
        let required = Set((root["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        var arguments: [ChatToolArgument] = []
        arguments.reserveCapacity(properties.count)
        for (name, schema) in properties {
            guard let kind = ChatArgumentKind(schema: schema) else { return nil }
            arguments.append(ChatToolArgument(name: name, kind: kind, isRequired: required.contains(name)))
        }
        return ChatToolManifest(name: tool.name, arguments: arguments)
    }
}

public extension ChatArgumentKind {
    /// The kind one ``ToolSchema`` property node declares.
    ///
    /// An `array` is accepted ONLY when its `items` are integers, because
    /// ``ToolSchema/integerArray(_:maxItems:)`` is the only array builder the tool
    /// layer has — an array of anything else means the schema grew a shape no
    /// wrapper knows how to restate, and `nil` is the honest answer.
    init?(schema: ToolboxJSON) {
        guard let node = schema.objectValue, let type = node["type"]?.stringValue else { return nil }
        switch type {
        case "string":
            self = .string
        case "integer":
            self = .integer
        case "number":
            self = .number
        case "array":
            guard node["items"]?.objectValue?["type"]?.stringValue == "integer" else { return nil }
            self = .integerArray
        default:
            return nil
        }
    }
}

// MARK: - Reading the Swift struct

public extension ChatToolManifest {
    /// The manifest a wrapper's `@Generable` `Arguments` value actually declares.
    ///
    /// Reflects over `arguments`, which must be a PROBE instance — every optional
    /// left `nil`, every required field filled. `nil` optionals are what make this
    /// work: `type(of:)` on an `Any`-boxed `nil` still reports `Optional<Int>`, so
    /// optionality and the wrapped type both survive the box. A filled optional
    /// would too, but a probe that leaves them empty also proves the struct is
    /// constructible in the state the model puts it in when it omits an argument.
    ///
    /// Returns `nil` if any property has a type outside ``ChatArgumentKind``'s
    /// four shapes, or is unlabelled.
    static func reflected(name: String, arguments: Any) -> ChatToolManifest? {
        var declared: [ChatToolArgument] = []
        for child in Mirror(reflecting: arguments).children {
            guard let label = child.label,
                  let shape = argumentShape(ofTypeNamed: String(describing: type(of: child.value)))
            else { return nil }
            declared.append(ChatToolArgument(name: label, kind: shape.kind, isRequired: shape.isRequired))
        }
        return ChatToolManifest(name: name, arguments: declared)
    }

    /// Maps a Swift type name onto a published argument shape.
    ///
    /// Spelled as a table rather than as `as?` casts because an `Any` holding a
    /// `nil` `Int?` casts to neither `Int` nor `Int?` usefully — the TYPE is the
    /// only surviving evidence, so the type name is what is matched. `Int64` is
    /// deliberately absent: it is not `Generable`, so a wrapper takes `[Int]` and
    /// widens at the boundary (see `LibraryChatTools+Answer.swift`).
    private static func argumentShape(
        ofTypeNamed typeName: String
    ) -> (kind: ChatArgumentKind, isRequired: Bool)? {
        let required: [String: ChatArgumentKind] = [
            "String": .string,
            "Int": .integer,
            "Double": .number,
            "Array<Int>": .integerArray,
        ]
        if let kind = required[typeName] {
            return (kind, true)
        }
        guard typeName.hasPrefix("Optional<"), typeName.hasSuffix(">") else { return nil }
        let wrapped = String(typeName.dropFirst("Optional<".count).dropLast())
        guard let kind = required[wrapped] else { return nil }
        return (kind, false)
    }
}
