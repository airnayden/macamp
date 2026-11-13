// ToolResult — what a tool answers with, and how that answer is squeezed into a
// tier's budget.
//
// ── EVERY TIER CONSUMES TEXT ──────────────────────────────────────────────────
//
// FoundationModels wants a `PromptRepresentable`, a provider loop wants a
// `tool_result` string, MCP wants text content. All three are strings, so the
// rendering — not the structure — is the contract, and ``renderedText(profile:)``
// is where the budget is enforced. ``payload`` is kept alongside for an adapter
// that would rather re-serialise the rows itself; it is never what the budget is
// measured against.
//
// ── EACH ROW PHRASES ITSELF ───────────────────────────────────────────────────
//
// A row carries a finished line rather than a field bag, because "128 bpm" and
// "1995" and "not analysed" want different phrasing and a generic joiner would
// produce the worst of the three. The tool that read the row knows how to say it.
//
// ── THE TWO CAPS, AND WHICH ONE WINS ──────────────────────────────────────────
//
// ``ToolProfile/rowLimit`` is a SOFT cap and ``ToolProfile/characterLimit`` is the
// HARD one: rows are dropped from the tail until the whole rendered result fits,
// and the "+N more" suffix counts everything dropped by EITHER cap. So a caller
// can rely on `renderedText(profile:).count <= profile.characterLimit`
// unconditionally — that is the property the on-device token budget depends on.
//
// ``totalCount`` is what the TOOL FOUND, which is itself bounded by
// ``ToolResultBudget/fetchLimit``. The suffix therefore states how many fetched
// rows were not rendered — a statement that is always exactly true — rather than
// guessing at how many rows the library holds.
//
// ── `resultCount` IS DATA, AND IT IS OPTIONAL FOR A REASON ───────────────────
//
// A shell wants to say "Searched your library — 12 results" beside a lookup, and
// the ONLY honest way to get that 12 is for the tool that built the rows to state
// it. Counting newlines in ``renderedText(profile:)`` — or reading a figure back
// out of ``summary`` — would be the "a shell that renders a model-facing string
// verbatim has a shell bug" failure one step removed, and would break the moment
// the "+N more" suffix or a tier's row budget changed.
//
// So ``resultCount`` is carried alongside the text, and it is `Int?` because
// "how many results" is not a question every answer can be asked: a refusal, a
// filed proposal and a listening digest are not lists, and `0` would be a wrong
// answer rather than an absent one. It is the PRE-truncation figure — what the
// tool found before ``renderedText(profile:)`` dropped rows to fit a budget —
// so a `.onDevice` render showing nine rows of a twenty-row search still reports
// twenty.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// One line of a tool's answer.
///
/// `Hashable` because ``ToolRunOutcome`` is, and now carries these.
public struct ToolResultRow: Sendable, Equatable, Hashable {
    /// The compact line, already phrased by the tool that produced it. Must not
    /// contain a newline — the renderer joins rows with one.
    public let text: String
    /// The same row in machine form, for an adapter that re-serialises.
    public let payload: ToolboxJSON

    public init(text: String, payload: ToolboxJSON = .null) {
        self.text = text.replacingOccurrences(of: "\n", with: " ")
        self.payload = payload
    }
}

/// A tool's answer: one summary line, a bounded list of rows, and the count of
/// rows the tool actually found.
public struct ToolResult: Sendable, Equatable {
    /// The leading line. May be empty, in which case no line is emitted for it.
    public let summary: String
    /// The rows, already bounded by the tool's own fetch cap.
    public let rows: [ToolResultRow]
    /// Rows the tool FOUND — always `>= rows.count`. See the file header.
    public let totalCount: Int
    /// How many results this answer is ABOUT, or `nil` when it is not list-shaped.
    ///
    /// Pre-truncation, so it survives a tier's row budget. See the file header for
    /// why it is optional rather than `0`.
    public let resultCount: Int?

    /// - Parameter totalCount: Defaults to `rows.count`. Pass a larger value only
    ///   when the tool genuinely knows more rows exist than it kept.
    /// - Parameter resultCount: Pass the row total for a LIST-shaped answer; leave
    ///   `nil` for a sentence, a digest or a filed proposal. Clamped to
    ///   `>= rows.count`, on the same reasoning as `totalCount`.
    public init(
        summary: String,
        rows: [ToolResultRow] = [],
        totalCount: Int? = nil,
        resultCount: Int? = nil
    ) {
        self.summary = summary.replacingOccurrences(of: "\n", with: " ")
        self.rows = rows
        self.totalCount = max(totalCount ?? rows.count, rows.count)
        self.resultCount = resultCount.map { max($0, rows.count) }
    }

    /// A result that is just a sentence — no rows, nothing to truncate but the
    /// sentence itself.
    ///
    /// Never list-shaped: this is how every refusal reaches a model, and "0
    /// results" beside a refusal would report a lookup that never happened.
    public static func message(_ text: String) -> ToolResult {
        ToolResult(summary: text)
    }

    /// The whole result in machine form.
    public var payload: ToolboxJSON {
        .object([
            "summary": .string(summary),
            "totalCount": .int(totalCount),
            "rows": .array(rows.map(\.payload)),
        ])
    }
}

// MARK: - Rendering

public extension ToolResult {
    /// The result as text, guaranteed to fit `profile`'s character budget.
    ///
    /// Deterministic: same rows in, same bytes out — which is what lets a test
    /// assert the exact string rather than a shape.
    func renderedText(profile: ToolProfile) -> String {
        let candidates = rows.prefix(profile.rowLimit).map {
            Self.elide($0.text, limit: profile.rowCharacterLimit)
        }
        for shown in stride(from: candidates.count, through: 0, by: -1) {
            let text = Self.assemble(
                summary: summary,
                rows: Array(candidates.prefix(shown)),
                omitted: totalCount - shown
            )
            if text.count <= profile.characterLimit || shown == 0 {
                return Self.elide(text, limit: profile.characterLimit)
            }
        }
        return Self.elide(summary, limit: profile.characterLimit)
    }

    /// The suffix appended when rows were dropped. Public so the tests — and a
    /// future adapter that wants to detect truncation — read the one definition.
    static func truncationSuffix(omitted: Int) -> String {
        "+\(omitted) more — refine your query"
    }
}

extension ToolResult {
    /// Joins the summary, the kept rows and the truncation suffix with newlines.
    static func assemble(summary: String, rows: [String], omitted: Int) -> String {
        var lines: [String] = []
        if !summary.isEmpty {
            lines.append(summary)
        }
        lines.append(contentsOf: rows)
        if omitted > 0 {
            lines.append(truncationSuffix(omitted: omitted))
        }
        return lines.joined(separator: "\n")
    }

    /// Truncates to `limit` CHARACTERS, marking the cut. Counting characters (not
    /// bytes) is what keeps a multi-byte title from being cut mid-scalar.
    static func elide(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let mark = ToolResultBudget.ellipsis
        return String(text.prefix(max(0, limit - mark.count))) + mark
    }
}
