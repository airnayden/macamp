// ToolArguments — the decoded argument object a tool executes against, plus the
// typed refusals it answers a malformed call with.
//
// ── EVERY MESSAGE IS ADDRESSED TO A MODEL, NOT TO A PERSON ────────────────────
//
// ``ToolArgumentError/message`` is protocol payload: it is handed straight back to
// the caller as the tool's result text so the model can CORRECT ITSELF and retry.
// That is the same audience `AssistantPrompts` writes for, and it is why these
// strings are English literals rather than `LocalizedStringResource`s — they are
// not user-visible copy, and localizing them would make the retry behaviour depend
// on the listener's language. A shell that ever renders one of these verbatim to a
// person has a bug in the shell.
//
// Each message names the argument, states what was expected, and (where there is
// one) states the bound — the three things a model needs to produce a valid second
// attempt.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Why a tool call could not be understood. Nothing was read and nothing was
/// written — argument validation happens before any repository is touched.
public enum ToolArgumentError: Error, Sendable, Equatable {
    /// The argument payload was not a JSON object.
    case notAnObject
    /// The payload was not valid JSON at all.
    case malformedJSON(reason: String)
    /// A required argument was absent or `null`.
    case missing(argument: String)
    /// A call gave none of a set of alternatives, at least one of which is needed.
    case missingAny(arguments: [String])
    /// An argument was present but of the wrong JSON type.
    case wrongType(argument: String, expected: String)
    /// A string or list argument was present but empty.
    case empty(argument: String)
    /// A list argument exceeded its documented ceiling.
    case tooMany(argument: String, limit: Int, found: Int)
    /// A value fell outside the argument's documented bounds.
    case outOfRange(argument: String, lower: Double, upper: Double)
    /// A value was not in the argument's closed vocabulary.
    case notAllowed(argument: String, allowed: [String])

    /// The sentence handed back to the model. See the file header.
    public var message: String {
        switch self {
        case .notAnObject:
            "Arguments must be a JSON object."
        case let .malformedJSON(reason):
            "Arguments were not valid JSON: \(reason)"
        case let .missing(argument):
            "Argument \"\(argument)\" is required."
        case let .missingAny(arguments):
            "At least one of these arguments is required: \(arguments.joined(separator: ", "))."
        case let .wrongType(argument, expected):
            "Argument \"\(argument)\" must be \(expected)."
        case let .empty(argument):
            "Argument \"\(argument)\" must not be empty."
        case let .tooMany(argument, limit, found):
            "Argument \"\(argument)\" accepts at most \(limit) items; \(found) were given."
        case let .outOfRange(argument, lower, upper):
            "Argument \"\(argument)\" must be between \(Self.bound(lower)) and \(Self.bound(upper))."
        case let .notAllowed(argument, allowed):
            "Argument \"\(argument)\" must be one of: \(allowed.joined(separator: ", "))."
        }
    }

    /// Renders a bound without a trailing `.0` on whole numbers, so an integer
    /// range reads as `1 and 50` rather than `1.0 and 50.0`.
    private static func bound(_ value: Double) -> String {
        value == value.rounded() && value.magnitude < 1e15
            ? String(Int64(value))
            : String(value)
    }
}

/// One tool call's decoded arguments.
public struct ToolArguments: Sendable, Equatable {
    /// The raw argument object, keyed by the names the schema declares.
    public let values: [String: ToolboxJSON]

    public init(_ values: [String: ToolboxJSON] = [:]) {
        self.values = values
    }

    /// Wraps a JSON value that must be an object.
    public init(json: ToolboxJSON) throws {
        guard let object = json.objectValue else { throw ToolArgumentError.notAnObject }
        values = object
    }

    /// Decodes a raw JSON argument payload.
    public static func decode(_ data: Data) throws -> ToolArguments {
        let json: ToolboxJSON
        do {
            json = try ToolboxJSON.decoded(from: data)
        } catch {
            throw ToolArgumentError.malformedJSON(reason: "\(error)")
        }
        return try ToolArguments(json: json)
    }

    /// Decodes a raw JSON argument string.
    public static func decode(_ text: String) throws -> ToolArguments {
        try decode(Data(text.utf8))
    }

    /// The value for `name`, treating an explicit `null` as absent.
    ///
    /// A model that fills every declared property (which OpenAI strict mode makes
    /// it do) sends `null` for the ones it does not mean — so `null` and absent
    /// have to be the same thing, or every optional argument would be mandatory.
    public func value(_ name: String) -> ToolboxJSON? {
        guard let value = values[name], !value.isNull else { return nil }
        return value
    }
}

// MARK: - Typed accessors

public extension ToolArguments {
    /// A required, non-empty string.
    func string(_ name: String) throws -> String {
        guard let value = value(name) else { throw ToolArgumentError.missing(argument: name) }
        guard let text = value.stringValue else {
            throw ToolArgumentError.wrongType(argument: name, expected: "a string")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolArgumentError.empty(argument: name)
        }
        return text
    }

    /// An optional, non-empty string. A present-but-blank value is `nil` rather
    /// than an error: a model padding an unused slot with `""` means "no filter".
    func optionalString(_ name: String) throws -> String? {
        guard let value = value(name) else { return nil }
        guard let text = value.stringValue else {
            throw ToolArgumentError.wrongType(argument: name, expected: "a string")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A required value from a closed vocabulary.
    func enumValue(_ name: String, allowed: [String]) throws -> String {
        let text = try string(name)
        guard allowed.contains(text) else {
            throw ToolArgumentError.notAllowed(argument: name, allowed: allowed)
        }
        return text
    }

    /// An optional value from a closed vocabulary.
    func optionalEnumValue(_ name: String, allowed: [String]) throws -> String? {
        guard let text = try optionalString(name) else { return nil }
        guard allowed.contains(text) else {
            throw ToolArgumentError.notAllowed(argument: name, allowed: allowed)
        }
        return text
    }

    /// An optional number, bounded inclusively.
    func optionalNumber(_ name: String, lower: Double, upper: Double) throws -> Double? {
        guard let value = value(name) else { return nil }
        guard let number = value.numberValue else {
            throw ToolArgumentError.wrongType(argument: name, expected: "a number")
        }
        guard number >= lower, number <= upper else {
            throw ToolArgumentError.outOfRange(argument: name, lower: lower, upper: upper)
        }
        return number
    }

    /// An optional integer, bounded inclusively. A fractional value is a type
    /// error rather than a silent truncation.
    func optionalInteger(_ name: String, lower: Int, upper: Int) throws -> Int? {
        guard let number = try optionalNumber(name, lower: Double(lower), upper: Double(upper)) else { return nil }
        guard number == number.rounded() else {
            throw ToolArgumentError.wrongType(argument: name, expected: "a whole number")
        }
        return Int(number)
    }

    /// A required integer, bounded inclusively.
    func integer(_ name: String, lower: Int, upper: Int) throws -> Int {
        guard let value = try optionalInteger(name, lower: lower, upper: upper) else {
            throw ToolArgumentError.missing(argument: name)
        }
        return value
    }

    /// A required, non-empty list of row ids, capped at `limit`.
    ///
    /// Duplicates are collapsed and original order is preserved, so a model that
    /// repeats an id gets one row back rather than two.
    func identifiers(_ name: String, limit: Int) throws -> [Int64] {
        guard let value = value(name) else { throw ToolArgumentError.missing(argument: name) }
        let ids = try Self.parsedIdentifiers(name, value, limit: limit)
        guard !ids.isEmpty else { throw ToolArgumentError.empty(argument: name) }
        return ids
    }

    /// An optional list of row ids, capped at `limit`.
    ///
    /// Absent — or present but EMPTY — is `nil`, on the same reasoning
    /// ``optionalString(_:)`` gives for a blank string: a model that fills every
    /// declared property pads an unused list with `[]`, and reading that as an
    /// error would make an optional argument mandatory again.
    func optionalIdentifiers(_ name: String, limit: Int) throws -> [Int64]? {
        guard let value = value(name) else { return nil }
        let ids = try Self.parsedIdentifiers(name, value, limit: limit)
        return ids.isEmpty ? nil : ids
    }

    /// Validates the list's type, its length and every element, leaving the caller
    /// to decide what an EMPTY list means — the one thing the two accessors above
    /// disagree about.
    private static func parsedIdentifiers(
        _ name: String,
        _ value: ToolboxJSON,
        limit: Int
    ) throws -> [Int64] {
        guard let items = value.arrayValue else {
            throw ToolArgumentError.wrongType(argument: name, expected: "an array of integers")
        }
        guard items.count <= limit else {
            throw ToolArgumentError.tooMany(argument: name, limit: limit, found: items.count)
        }
        var seen = Set<Int64>()
        return try items.map { item in
            guard let number = item.numberValue, number == number.rounded() else {
                throw ToolArgumentError.wrongType(argument: name, expected: "an array of integers")
            }
            return Int64(number)
        }.filter { seen.insert($0).inserted }
    }

    /// A required, non-empty list of nested argument objects, capped at `limit`.
    ///
    /// Each element comes back as a ``ToolArguments`` of its own, so the field
    /// accessors above read a nested object exactly as they read a top-level one
    /// and every element inherits the same refusal vocabulary. Duplicates are NOT
    /// collapsed — unlike an id list, two identical `{title, artist}` requests are
    /// two things the caller asked for and each deserves its own answer.
    func objectArray(_ name: String, limit: Int) throws -> [ToolArguments] {
        guard let value = value(name) else { throw ToolArgumentError.missing(argument: name) }
        guard let items = value.arrayValue else {
            throw ToolArgumentError.wrongType(argument: name, expected: "an array of objects")
        }
        guard !items.isEmpty else { throw ToolArgumentError.empty(argument: name) }
        guard items.count <= limit else {
            throw ToolArgumentError.tooMany(argument: name, limit: limit, found: items.count)
        }
        return try items.map { item in
            guard let object = item.objectValue else {
                throw ToolArgumentError.wrongType(argument: name, expected: "an array of objects")
            }
            return ToolArguments(object)
        }
    }
}
