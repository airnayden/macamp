// AutoEqProfileParser — reads an AutoEq `ParametricEQ.txt` headphone profile.
//
// AutoEq (github.com/jaakkopasanen/AutoEq) publishes a per-headphone correction
// curve in several formats; `ParametricEQ.txt` is the one that maps onto a
// parametric EQ. Its grammar is fixed and line-oriented:
//
//     Preamp: -6.1 dB
//     Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
//     Filter 2: ON PK Fc 8800 Hz Gain 5.1 dB Q 1.42
//
// The parser is deliberately STRICT: keyword spelling and token order must match
// exactly. A profile whose numbers are read wrong is worse than one that is
// refused, because the result is a plausible-looking curve that is silently not
// the headphone's correction. Every rejection carries the 1-based line number so
// the import UI (todo 21) can point at the offending line.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

// MARK: - Errors

/// A typed failure from ``AutoEqProfileParser``.
///
/// The cases carry data, not prose: PlayerCore never holds user-facing copy.
/// The import UI (todo 21) maps each case onto a String Catalog entry.
public enum AutoEqParseError: Error, Equatable, Sendable {
    /// A non-empty line matched neither the `Preamp:` nor the `Filter N:` shape.
    case malformedLine(lineNumber: Int, content: String)
    /// A `Filter N:` line named a filter type MacAMP does not support.
    ///
    /// The common real-world case is the **legacy `LS`/`HS` spelling**. AutoEq
    /// emits `LSC`/`HSC`, and the two conventions disagree about whether `Fc` is
    /// the shelf's corner or its mid-point frequency — so a legacy file is
    /// refused rather than silently mis-tuned by half a shelf.
    case unsupportedFilterType(lineNumber: Int, token: String)
    /// A numeric field (`Fc`, `Gain`, or `Q`) was not a parseable decimal.
    case malformedNumber(lineNumber: Int, field: String, token: String)
    /// The file carried more than one `Preamp:` line.
    case duplicatePreamp(lineNumber: Int)
    /// The file parsed cleanly but contained no enabled (`ON`) filter, so
    /// importing it would silently produce a flat EQ.
    case noEnabledFilters
    /// The file declared more enabled filters than the parametric node has bands
    /// (``ParametricEQConfiguration/maximumFilterCount``).
    case tooManyFilters(count: Int, maximum: Int)

    /// The 1-based line the failure occurred on, when the failure is tied to one.
    public var lineNumber: Int? {
        switch self {
        case let .malformedLine(lineNumber, _),
             let .unsupportedFilterType(lineNumber, _),
             let .malformedNumber(lineNumber, _, _),
             let .duplicatePreamp(lineNumber):
            lineNumber
        case .noEnabledFilters, .tooManyFilters:
            nil
        }
    }
}

// MARK: - Parser

/// Reads AutoEq `ParametricEQ.txt` profiles into a ``ParametricEQConfiguration``.
public enum AutoEqProfileParser {
    /// Parses the contents of an AutoEq `ParametricEQ.txt` profile.
    ///
    /// Blank lines are ignored. `OFF` filter lines are skipped without further
    /// validation — exporters pad a fixed-length filter bank with disabled rows
    /// (`Filter 11: OFF None`), and a disabled row contributes nothing.
    ///
    /// A missing `Preamp:` line is not an error; the pre-amp defaults to 0 dB.
    ///
    /// - Throws: ``AutoEqParseError``.
    public static func parse(_ text: String) throws -> ParametricEQConfiguration {
        var preampDB: Double?
        var filters: [ParametricFilter] = []

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)

            switch tokens[0] {
            case Keyword.preamp:
                guard preampDB == nil else { throw AutoEqParseError.duplicatePreamp(lineNumber: lineNumber) }
                preampDB = try parsePreamp(tokens: tokens, lineNumber: lineNumber, content: line)
            case Keyword.filter:
                if let filter = try parseFilter(tokens: tokens, lineNumber: lineNumber, content: line) {
                    filters.append(filter)
                }
            default:
                throw AutoEqParseError.malformedLine(lineNumber: lineNumber, content: line)
            }
        }

        guard !filters.isEmpty else { throw AutoEqParseError.noEnabledFilters }
        let maximum = ParametricEQConfiguration.maximumFilterCount
        guard filters.count <= maximum else {
            throw AutoEqParseError.tooManyFilters(count: filters.count, maximum: maximum)
        }
        return ParametricEQConfiguration(filters: filters, preampDB: preampDB ?? 0)
    }

    /// Reads and parses an AutoEq profile from disk.
    ///
    /// - Throws: ``AutoEqParseError``, or any `Error` raised while reading `url`.
    public static func parse(contentsOf url: URL) throws -> ParametricEQConfiguration {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}

// MARK: - Line grammar

private extension AutoEqProfileParser {
    enum Keyword {
        static let preamp = "Preamp:"
        static let filter = "Filter"
        static let enabled = "ON"
        static let disabled = "OFF"
        static let frequency = "Fc"
        static let hertz = "Hz"
        static let gain = "Gain"
        static let decibels = "dB"
        static let qFactor = "Q"
    }

    enum Field {
        static let preamp = "Preamp"
        static let frequency = "Fc"
        static let gain = "Gain"
        static let qFactor = "Q"
    }

    /// `Preamp: <value> dB`
    static func parsePreamp(tokens: [String], lineNumber: Int, content: String) throws -> Double {
        guard tokens.count == 3, tokens[2] == Keyword.decibels else {
            throw AutoEqParseError.malformedLine(lineNumber: lineNumber, content: content)
        }
        return try number(tokens[1], field: Field.preamp, lineNumber: lineNumber)
    }

    /// `Filter <N>: ON <TYPE> Fc <f> Hz Gain <g> dB Q <q>`
    ///
    /// Returns `nil` for a disabled (`OFF`) row, which is skipped.
    static func parseFilter(tokens: [String], lineNumber: Int, content: String) throws -> ParametricFilter? {
        guard tokens.count >= 3, isFilterIndex(tokens[1]) else {
            throw AutoEqParseError.malformedLine(lineNumber: lineNumber, content: content)
        }
        switch tokens[2] {
        case Keyword.disabled: return nil
        case Keyword.enabled: break
        default: throw AutoEqParseError.malformedLine(lineNumber: lineNumber, content: content)
        }

        guard tokens.count == 12,
              tokens[4] == Keyword.frequency, tokens[6] == Keyword.hertz,
              tokens[7] == Keyword.gain, tokens[9] == Keyword.decibels,
              tokens[10] == Keyword.qFactor
        else {
            throw AutoEqParseError.malformedLine(lineNumber: lineNumber, content: content)
        }
        guard let type = ParametricFilterType(rawValue: tokens[3]) else {
            throw AutoEqParseError.unsupportedFilterType(lineNumber: lineNumber, token: tokens[3])
        }
        return try ParametricFilter(
            type: type,
            frequency: number(tokens[5], field: Field.frequency, lineNumber: lineNumber),
            gainDB: number(tokens[8], field: Field.gain, lineNumber: lineNumber),
            qFactor: number(tokens[11], field: Field.qFactor, lineNumber: lineNumber)
        )
    }

    /// Whether `token` is the `<N>:` index of a `Filter` line.
    static func isFilterIndex(_ token: String) -> Bool {
        guard token.hasSuffix(":") else { return false }
        let digits = token.dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    /// Parses a decimal field. `Double(String)` is locale-independent (always a
    /// `.` decimal separator), which is exactly what the file format specifies —
    /// a `NumberFormatter` would misread the file under a comma-decimal locale.
    static func number(_ token: String, field: String, lineNumber: Int) throws -> Double {
        guard let value = Double(token), value.isFinite else {
            throw AutoEqParseError.malformedNumber(lineNumber: lineNumber, field: field, token: token)
        }
        return value
    }
}
