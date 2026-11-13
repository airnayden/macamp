import Foundation
@testable import Services
import Testing

/// Argument decoding and the refusals a malformed call gets back.
///
/// Every message is asserted verbatim, because it is protocol payload the model
/// reads and retries against — a vaguer sentence is a real regression, not a
/// cosmetic one.
@Suite("ToolArguments")
struct ToolArgumentsTests {
    @Test("a JSON object decodes into typed values")
    func decodesAnObject() throws {
        let arguments = try ToolArguments.decode(#"{"query":"aurora","limit":5,"loud":true}"#)
        try #expect(arguments.string("query") == "aurora")
        try #expect(arguments.optionalInteger("limit", lower: 1, upper: 50) == 5)
        #expect(arguments.value("loud")?.boolValue == true)
    }

    @Test("a non-object payload is refused")
    func refusesANonObject() throws {
        #expect(throws: ToolArgumentError.notAnObject) {
            try ToolArguments.decode("[1, 2, 3]")
        }
    }

    @Test("malformed JSON is refused with a reason, not a crash")
    func refusesMalformedJSON() throws {
        var thrown: ToolArgumentError?
        do {
            _ = try ToolArguments.decode("{not json")
        } catch let error as ToolArgumentError {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error.message.hasPrefix("Arguments were not valid JSON:"))
    }

    @Test("an explicit null reads as absent, so an optional argument stays optional")
    func nullIsAbsent() throws {
        let arguments = try ToolArguments.decode(#"{"query":"x","genre":null}"#)
        try #expect(arguments.optionalString("genre") == nil)
        #expect(arguments.value("genre") == nil)
    }

    @Test("a missing required argument names itself")
    func missingArgument() throws {
        let arguments = ToolArguments()
        #expect(throws: ToolArgumentError.missing(argument: "query")) {
            try arguments.string("query")
        }
        #expect(ToolArgumentError.missing(argument: "query").message == "Argument \"query\" is required.")
    }

    @Test("a wrong type states what was expected")
    func wrongType() throws {
        let arguments = try ToolArguments.decode(#"{"query":42}"#)
        #expect(throws: ToolArgumentError.wrongType(argument: "query", expected: "a string")) {
            try arguments.string("query")
        }
        #expect(
            ToolArgumentError.wrongType(argument: "query", expected: "a string").message
                == "Argument \"query\" must be a string."
        )
    }

    @Test("a blank required string is refused, but a blank optional one is just absent")
    func blankHandling() throws {
        let arguments = try ToolArguments.decode(#"{"query":"   ","genre":"  "}"#)
        #expect(throws: ToolArgumentError.empty(argument: "query")) {
            try arguments.string("query")
        }
        try #expect(arguments.optionalString("genre") == nil)
    }

    @Test("a closed vocabulary lists its options")
    func enumVocabulary() throws {
        let arguments = try ToolArguments.decode(#"{"window":"yesterday"}"#)
        #expect(throws: ToolArgumentError.notAllowed(argument: "window", allowed: ["7d", "all"])) {
            try arguments.enumValue("window", allowed: ["7d", "all"])
        }
        #expect(
            ToolArgumentError.notAllowed(argument: "window", allowed: ["7d", "all"]).message
                == "Argument \"window\" must be one of: 7d, all."
        )
    }

    @Test("an out-of-range number states the bounds without a spurious decimal point")
    func outOfRange() throws {
        let arguments = try ToolArguments.decode(#"{"limit":900}"#)
        #expect(throws: ToolArgumentError.outOfRange(argument: "limit", lower: 1, upper: 50)) {
            try arguments.optionalInteger("limit", lower: 1, upper: 50)
        }
        #expect(
            ToolArgumentError.outOfRange(argument: "limit", lower: 1, upper: 50).message
                == "Argument \"limit\" must be between 1 and 50."
        )
    }

    @Test("a fractional value is a type error rather than a silent truncation")
    func fractionalInteger() throws {
        let arguments = try ToolArguments.decode(#"{"limit":2.5}"#)
        #expect(throws: ToolArgumentError.wrongType(argument: "limit", expected: "a whole number")) {
            try arguments.optionalInteger("limit", lower: 1, upper: 50)
        }
    }

    @Test("an id list is required, non-empty, integral and capped")
    func identifierValidation() throws {
        let empty = try ToolArguments.decode(#"{"track_ids":[]}"#)
        #expect(throws: ToolArgumentError.empty(argument: "track_ids")) {
            try empty.identifiers("track_ids", limit: 100)
        }

        let wrong = try ToolArguments.decode(#"{"track_ids":["3"]}"#)
        #expect(throws: ToolArgumentError.wrongType(argument: "track_ids", expected: "an array of integers")) {
            try wrong.identifiers("track_ids", limit: 100)
        }

        let over = try ToolArguments.decode(#"{"track_ids":[1,2,3,4]}"#)
        #expect(throws: ToolArgumentError.tooMany(argument: "track_ids", limit: 3, found: 4)) {
            try over.identifiers("track_ids", limit: 3)
        }
        #expect(
            ToolArgumentError.tooMany(argument: "track_ids", limit: 3, found: 4).message
                == "Argument \"track_ids\" accepts at most 3 items; 4 were given."
        )
    }

    @Test("repeated ids collapse but keep the order they were asked in")
    func identifiersDeduplicate() throws {
        let arguments = try ToolArguments.decode(#"{"track_ids":[9,3,9,1,3]}"#)
        try #expect(arguments.identifiers("track_ids", limit: 100) == [9, 3, 1])
    }
}
