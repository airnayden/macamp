import AudioEngine
import Foundation
import Testing

@Suite("AutoEqProfileParser")
struct AutoEqProfileParserTests {
    // MARK: - Committed real fixture

    /// The exact contents of `Sennheiser HD 650 ParametricEQ.txt`, transcribed
    /// by hand from the committed file so the assertion is an independent
    /// statement of what the file says rather than an echo of the parser.
    private static let hd650Expected: [ParametricFilter] = [
        ParametricFilter(type: .lowShelf, frequency: 105, gainDB: 6.4, qFactor: 0.70),
        ParametricFilter(type: .peaking, frequency: 8800, gainDB: 5.1, qFactor: 1.42),
        ParametricFilter(type: .peaking, frequency: 118, gainDB: -3.1, qFactor: 0.50),
        ParametricFilter(type: .peaking, frequency: 37, gainDB: 0.7, qFactor: 3.96),
        ParametricFilter(type: .peaking, frequency: 3169, gainDB: -1.7, qFactor: 3.89),
        ParametricFilter(type: .highShelf, frequency: 10000, gainDB: -2.1, qFactor: 0.70),
        ParametricFilter(type: .peaking, frequency: 1227, gainDB: -1.2, qFactor: 2.53),
        ParametricFilter(type: .peaking, frequency: 2055, gainDB: 1.2, qFactor: 3.23),
        ParametricFilter(type: .peaking, frequency: 587, gainDB: 0.4, qFactor: 1.19),
        ParametricFilter(type: .peaking, frequency: 5332, gainDB: -1.1, qFactor: 5.75),
    ]

    @Test("committed AutoEq fixture parses to the exact expected type / Fc / gain / Q and preamp")
    func fixtureParsesExactly() throws {
        let config = try AutoEqProfileParser.parse(contentsOf: TestFixtures.sennheiserHD650)

        #expect(config.preampDB == -6.1)
        #expect(config.filters.count == Self.hd650Expected.count)

        for (index, expected) in Self.hd650Expected.enumerated() {
            let filter = config.filters[index]
            #expect(filter.type == expected.type, "filter \(index + 1) type")
            #expect(filter.frequency == expected.frequency, "filter \(index + 1) Fc")
            #expect(filter.gainDB == expected.gainDB, "filter \(index + 1) gain")
            #expect(filter.qFactor == expected.qFactor, "filter \(index + 1) Q")
        }
        #expect(config.filters == Self.hd650Expected)
    }

    @Test("committed fixture's 0.70 shelves are inside the tolerance band and are not flagged")
    func fixtureShelvesAreNotFlagged() throws {
        let config = try AutoEqProfileParser.parse(contentsOf: TestFixtures.sennheiserHD650)
        #expect(config.hasApproximatedShelfSlope == false)
        #expect(config.approximatedShelfFilterIndices.isEmpty)
    }

    @Test("parse(contentsOf:) and parse(_:) agree")
    func fileAndStringAgree() throws {
        let fromFile = try AutoEqProfileParser.parse(contentsOf: TestFixtures.sennheiserHD650)
        let fromText = try AutoEqProfileParser.parse(TestFixtures.text(TestFixtures.sennheiserHD650))
        #expect(fromFile == fromText)
    }

    // MARK: - Grammar guard: legacy LS / HS

    @Test("legacy LS-typed profile is rejected with a typed error naming the line")
    func legacyLowShelfRejected() {
        let text = """
        Preamp: -6.1 dB
        Filter 1: ON LS Fc 105 Hz Gain 6.4 dB Q 0.70
        Filter 2: ON PK Fc 8800 Hz Gain 5.1 dB Q 1.42
        """
        #expect(throws: AutoEqParseError.unsupportedFilterType(lineNumber: 2, token: "LS")) {
            try AutoEqProfileParser.parse(text)
        }
    }

    @Test("legacy HS-typed profile is rejected with a typed error naming the line")
    func legacyHighShelfRejected() {
        let text = """
        Preamp: 0.0 dB
        Filter 1: ON PK Fc 105 Hz Gain 6.4 dB Q 0.70
        Filter 2: ON HS Fc 10000 Hz Gain -2.1 dB Q 0.70
        """
        #expect(throws: AutoEqParseError.unsupportedFilterType(lineNumber: 3, token: "HS")) {
            try AutoEqProfileParser.parse(text)
        }
    }

    @Test("an unknown filter type is rejected rather than silently skipped")
    func unknownFilterTypeRejected() {
        let text = "Filter 1: ON NOTCH Fc 105 Hz Gain 6.4 dB Q 0.70"
        #expect(throws: AutoEqParseError.unsupportedFilterType(lineNumber: 1, token: "NOTCH")) {
            try AutoEqProfileParser.parse(text)
        }
    }

    // MARK: - Malformed input

    @Test("a malformed filter line throws a typed error naming its 1-based line number")
    func malformedLineNamesLineNumber() throws {
        let text = """
        Preamp: -6.1 dB
        Filter 1: ON PK Fc 105 Hz Gain 6.4 dB Q 0.70
        Filter 2: ON PK Fc 8800 Hz Gain 5.1 dB
        """
        let error = try #require(capture { try AutoEqProfileParser.parse(text) })
        #expect(error == .malformedLine(lineNumber: 3, content: "Filter 2: ON PK Fc 8800 Hz Gain 5.1 dB"))
        #expect(error.lineNumber == 3)
    }

    @Test("a line that is neither Preamp nor Filter throws at its own line number")
    func unknownLineNamesLineNumber() throws {
        let text = """
        Preamp: -6.1 dB

        Bandwidth: 1 octave
        Filter 1: ON PK Fc 105 Hz Gain 6.4 dB Q 0.70
        """
        let error = try #require(capture { try AutoEqProfileParser.parse(text) })
        #expect(error == .malformedLine(lineNumber: 3, content: "Bandwidth: 1 octave"))
    }

    @Test("a non-numeric field throws malformedNumber naming the field and line")
    func nonNumericFieldRejected() throws {
        let text = "Filter 1: ON PK Fc abc Hz Gain 6.4 dB Q 0.70"
        let error = try #require(capture { try AutoEqProfileParser.parse(text) })
        #expect(error == .malformedNumber(lineNumber: 1, field: "Fc", token: "abc"))
    }

    @Test("a non-numeric preamp throws malformedNumber on the preamp line")
    func nonNumericPreampRejected() throws {
        let error = try #require(capture { try AutoEqProfileParser.parse("Preamp: none dB") })
        #expect(error == .malformedNumber(lineNumber: 1, field: "Preamp", token: "none"))
    }

    @Test("a second Preamp line is rejected rather than silently overwriting the first")
    func duplicatePreampRejected() {
        let text = """
        Preamp: -6.1 dB
        Preamp: -3.0 dB
        Filter 1: ON PK Fc 105 Hz Gain 6.4 dB Q 0.70
        """
        #expect(throws: AutoEqParseError.duplicatePreamp(lineNumber: 2)) {
            try AutoEqProfileParser.parse(text)
        }
    }

    // MARK: - Semantic guards

    @Test("a profile with no enabled filter is rejected instead of importing as flat")
    func noEnabledFiltersRejected() {
        let text = """
        Preamp: 0.0 dB
        Filter 1: OFF None
        Filter 2: OFF PK Fc 0 Hz Gain 0.0 dB Q 1.00
        """
        #expect(throws: AutoEqParseError.noEnabledFilters) {
            try AutoEqProfileParser.parse(text)
        }
    }

    @Test("more enabled filters than the node has bands is rejected with both counts")
    func tooManyFiltersRejected() {
        let maximum = ParametricEQConfiguration.maximumFilterCount
        let lines = (1 ... maximum + 1).map { "Filter \($0): ON PK Fc \($0 * 100) Hz Gain 1.0 dB Q 1.00" }
        #expect(throws: AutoEqParseError.tooManyFilters(count: maximum + 1, maximum: maximum)) {
            try AutoEqProfileParser.parse(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Tolerated input

    @Test("OFF rows are skipped without validating their remaining tokens")
    func disabledRowsSkipped() throws {
        let text = """
        Preamp: -1.0 dB
        Filter 1: ON PK Fc 105 Hz Gain 6.4 dB Q 0.70
        Filter 2: OFF None
        Filter 3: OFF LS Fc 0 Hz Gain 0.0 dB Q 1.00
        """
        let config = try AutoEqProfileParser.parse(text)
        #expect(config.filters.count == 1)
        #expect(config.filters[0].frequency == 105)
    }

    @Test("blank lines, CRLF endings, and a missing preamp are all tolerated")
    func whitespaceAndMissingPreampTolerated() throws {
        let text = "\r\n  \r\nFilter 1: ON PK Fc 105 Hz Gain 6.4 dB Q 0.70\r\n"
        let config = try AutoEqProfileParser.parse(text)
        #expect(config.preampDB == 0)
        #expect(config.filters.count == 1)
        #expect(config.filters[0].gainDB == 6.4)
    }

    @Test("decimal fields are read locale-independently, never through a formatter")
    func decimalsAreLocaleIndependent() throws {
        let config = try AutoEqProfileParser.parse("Filter 1: ON PK Fc 1234.5 Hz Gain -1.75 dB Q 0.707")
        #expect(config.filters[0].frequency == 1234.5)
        #expect(config.filters[0].gainDB == -1.75)
        #expect(config.filters[0].qFactor == 0.707)
    }
}

// MARK: - Helper

/// Runs `body` and returns the ``AutoEqParseError`` it threw, or `nil`.
///
/// Swift Testing's `#expect(throws:)` asserts equality but does not hand the
/// error back, and several cases here assert on a second property
/// (``AutoEqParseError/lineNumber``) of the same thrown value.
private func capture(_ body: () throws -> some Any) -> AutoEqParseError? {
    do {
        _ = try body()
        return nil
    } catch let error as AutoEqParseError {
        return error
    } catch {
        return nil
    }
}
