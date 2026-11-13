// ParametricEQFailureCopy — turns a `ParametricEQFailure` into listener copy.
//
// PlayerCore's failures carry DATA, not prose: `AutoEqParseError` knows the line
// number and the offending token, and `ParametricEQFailure` knows the filter count
// and the preset name, but neither holds an English sentence. This file is the one
// place that mapping happens, mirroring `LibraryChatFailureCopy`'s role for the
// chat surface.
//
// Every switch here is EXHAUSTIVE with no `default:`. Both enums are repo-internal,
// so a case added later must be given copy before the shell compiles — which is
// the point: a refusal a listener cannot read is worse than no refusal at all.
import AudioEngine
import Foundation
import ViewModels

enum ParametricEQFailureCopy {
    static func message(for failure: ParametricEQFailure) -> LocalizedStringResource {
        switch failure {
        case let .profileUnreadable(fileName):
            unreadableFile(fileName)
        case let .profileInvalid(parseError):
            message(for: parseError)
        case let .capacityExceeded(count, maximum):
            tooManyFilters(count: count, maximum: maximum)
        case let .presetUnreadable(name):
            presetUnreadable(name)
        case let .presetWriteFailed(name):
            presetWriteFailed(name)
        case .engineRefused:
            engineRefused
        }
    }

    /// The line number is surfaced wherever the parser knows one — it is the whole
    /// reason `AutoEqParseError` carries it, and it turns "this file is wrong" into
    /// something the listener can actually go and look at.
    static func message(for error: AutoEqParseError) -> LocalizedStringResource {
        switch error {
        case let .malformedLine(lineNumber, _):
            malformedLine(lineNumber)
        case let .unsupportedFilterType(lineNumber, token):
            unsupportedType(lineNumber: lineNumber, token: token)
        case let .malformedNumber(lineNumber, _, token):
            malformedNumber(lineNumber: lineNumber, token: token)
        case let .duplicatePreamp(lineNumber):
            duplicatePreamp(lineNumber)
        case .noEnabledFilters:
            noEnabledFilters
        case let .tooManyFilters(count, maximum):
            tooManyFilters(count: count, maximum: maximum)
        }
    }
}

// MARK: - Cases

private extension ParametricEQFailureCopy {
    static func unreadableFile(_ fileName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.unreadableFile",
            defaultValue: "MacAMP couldn’t read “\(fileName)”. Check that the file is still there and is a plain text profile.",
            comment: "Error shown when an AutoEq profile file could not be read at all"
        )
    }

    static func malformedLine(_ lineNumber: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.malformedLine",
            defaultValue: "Line \(lineNumber) isn’t in AutoEq’s format. MacAMP stopped rather than guess what it meant.",
            comment: "Error shown when a line of an AutoEq profile does not match the expected grammar"
        )
    }

    static func unsupportedType(lineNumber: Int, token: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.unsupportedType",
            defaultValue: "Line \(lineNumber) uses the filter type “\(token)”, which MacAMP doesn’t support. Export the profile again with PK, LSC and HSC filters.",
            comment: "Error shown for an AutoEq filter type token MacAMP does not support, such as the legacy LS or HS"
        )
    }

    static func malformedNumber(lineNumber: Int, token: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.malformedNumber",
            defaultValue: "Line \(lineNumber) has “\(token)” where a number was expected.",
            comment: "Error shown when a numeric field of an AutoEq profile line could not be read as a number"
        )
    }

    static func duplicatePreamp(_ lineNumber: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.duplicatePreamp",
            defaultValue: "This profile sets the pre-amp twice — the second one is on line \(lineNumber).",
            comment: "Error shown when an AutoEq profile contains more than one Preamp line"
        )
    }

    static var noEnabledFilters: LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.noFilters",
            defaultValue: "This profile has no filters switched on, so there is nothing to apply.",
            comment: "Error shown when every filter in an AutoEq profile is marked OFF"
        )
    }

    static func tooManyFilters(count: Int, maximum: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.tooManyFilters",
            defaultValue: "That would be \(count) filters and MacAMP can hold \(maximum).",
            comment: "Error shown when a profile, a preset or an edit would exceed the parametric equalizer's band count"
        )
    }

    static func presetUnreadable(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.presetUnreadable",
            defaultValue: "The saved preset “\(name)” can’t be read. You can delete it from the list.",
            comment: "Error shown when a saved parametric preset's stored filter bank could not be decoded"
        )
    }

    static func presetWriteFailed(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.presetWriteFailed",
            defaultValue: "MacAMP couldn’t save “\(name)”. Try again, or use a different name.",
            comment: "Error shown when a parametric preset could not be written to or deleted from storage"
        )
    }

    static var engineRefused: LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.error.engineRefused",
            defaultValue: "The audio engine turned these filters down. Your previous settings are still in place.",
            comment: "Error shown when the playback engine refused a parametric configuration for an unnamed reason"
        )
    }
}
