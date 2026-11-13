import Foundation
@testable import Services
import Testing

/// The budget contract: a rendered result NEVER exceeds its tier's character
/// limit, whatever the rows look like, and says how much it dropped.
@Suite("ToolResult rendering")
struct ToolResultRenderingTests {
    private func rows(_ count: Int) -> [ToolResultRow] {
        (0 ..< count).map { ToolResultRow(text: "row \($0)") }
    }

    @Test("a result that fits renders whole, exactly")
    func rendersWhole() {
        let result = ToolResult(summary: "3 things.", rows: [
            ToolResultRow(text: "alpha"),
            ToolResultRow(text: "bravo"),
            ToolResultRow(text: "charlie"),
        ])
        #expect(result.renderedText(profile: .cloud) == "3 things.\nalpha\nbravo\ncharlie")
    }

    @Test("an empty summary contributes no line")
    func emptySummaryIsOmitted() {
        let result = ToolResult(summary: "", rows: [ToolResultRow(text: "alpha")])
        #expect(result.renderedText(profile: .cloud) == "alpha")
    }

    @Test("the row limit drops the tail and says how many")
    func rowLimitAddsTheSuffix() {
        let result = ToolResult(summary: "", rows: rows(25))
        let rendered = result.renderedText(profile: .onDevice)
        let expected = (0 ..< ToolResultBudget.onDeviceRowLimit)
            .map { "row \($0)" }
            .joined(separator: "\n")
            + "\n" + ToolResult.truncationSuffix(omitted: 25 - ToolResultBudget.onDeviceRowLimit)
        #expect(rendered == expected)
    }

    @Test("the character limit is the HARD cap and drops rows the row limit kept")
    func characterLimitWins() {
        let wide = (0 ..< 20).map { index in
            ToolResultRow(text: String(repeating: "x", count: 300) + "\(index)")
        }
        let rendered = ToolResult(summary: "", rows: wide).renderedText(profile: .onDevice)
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let suffixLines = lines.filter { $0.hasSuffix("more — refine your query") }

        #expect(rendered.count <= ToolProfile.onDevice.characterLimit)
        #expect(suffixLines.count == 1)
        #expect(lines.count - 1 < ToolResultBudget.onDeviceRowLimit, "the hard cap did not bite")
        for line in lines where !line.hasSuffix("more — refine your query") {
            #expect(line.count == ToolResultBudget.onDeviceRowCharacterLimit)
            #expect(line.hasSuffix(ToolResultBudget.ellipsis))
        }
    }

    @Test("every tier's budget holds for a deliberately oversized result")
    func everyTierStaysInBudget() {
        let huge = (0 ..< 500).map { index in
            ToolResultRow(text: String(repeating: "y", count: 400) + "\(index)")
        }
        let result = ToolResult(summary: String(repeating: "s", count: 200), rows: huge)
        for profile in ToolProfile.allCases {
            let rendered = result.renderedText(profile: profile)
            #expect(rendered.count <= profile.characterLimit, "\(profile) overflowed")
        }
    }

    @Test("rendering is a pure function of the rows")
    func renderingIsDeterministic() {
        let result = ToolResult(summary: "12 things.", rows: rows(12))
        for profile in ToolProfile.allCases {
            #expect(result.renderedText(profile: profile) == result.renderedText(profile: profile))
        }
    }

    @Test("totalCount can never be smaller than the rows it counts")
    func totalCountIsAFloor() {
        let result = ToolResult(summary: "", rows: rows(5), totalCount: 2)
        #expect(result.totalCount == 5)
        #expect(!result.renderedText(profile: .cloud).contains("more — refine your query"))
    }

    @Test("a newline inside a row can never forge an extra line")
    func rowsCannotInjectLines() {
        let result = ToolResult(summary: "a\nb", rows: [ToolResultRow(text: "c\nd")])
        #expect(result.renderedText(profile: .cloud) == "a b\nc d")
    }

    @Test("a message result is just its sentence")
    func messageResult() {
        #expect(ToolResult.message("Nothing to report.").renderedText(profile: .onDevice) == "Nothing to report.")
    }

    @Test("the tiers are ordered smallest to largest, as documented")
    func budgetsAreOrdered() {
        #expect(ToolProfile.onDevice.characterLimit < ToolProfile.cloud.characterLimit)
        #expect(ToolProfile.cloud.characterLimit < ToolProfile.external.characterLimit)
        #expect(ToolProfile.onDevice.rowLimit < ToolProfile.cloud.rowLimit)
        #expect(ToolProfile.cloud.rowLimit < ToolProfile.external.rowLimit)
        #expect(ToolProfile.onDevice.restrictsToolCount)
        #expect(!ToolProfile.cloud.restrictsToolCount)
        #expect(!ToolProfile.external.restrictsToolCount)
    }

    @Test("the machine payload carries the same counts the text reports")
    func payloadMirrorsTheResult() throws {
        let result = ToolResult(summary: "two", rows: [
            ToolResultRow(text: "alpha", payload: .object(["id": .int(1)])),
            ToolResultRow(text: "bravo", payload: .object(["id": .int(2)])),
        ])
        let payload = try #require(result.payload.objectValue)
        #expect(payload["summary"]?.stringValue == "two")
        #expect(payload["totalCount"]?.numberValue == 2)
        #expect(payload["rows"]?.arrayValue?.count == 2)
    }
}
