// ToolProfile / ToolResultBudget — WHO is calling, and therefore how much text a
// result may occupy.
//
// ── ONE PLACE, BECAUSE THE CONSENT COPY WILL CITE THESE NUMBERS ───────────────
//
// Every cap is a named constant on ``ToolResultBudget`` with a doc comment saying
// what it buys, for the same reason `ConnectorPayloadBudget` centralises the
// connector payload limits: the numbers end up quoted in user-facing consent copy
// and in provider documentation, and a figure that lives in two places eventually
// disagrees with itself. Read a cap through ``ToolProfile`` (`characterLimit`,
// `rowLimit`, `rowCharacterLimit`); never hard-code one at a call site.
//
// ── WHY THE ON-DEVICE TIER IS SO MUCH SMALLER ─────────────────────────────────
//
// A FoundationModels session carries its tool definitions AND every tool result in
// a 4096-token context that also has to hold the conversation. A 600-character
// result is roughly 150 tokens; ten of those still leave the session room to
// answer. An 8 KB cloud result would consume half the window on its own.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Which adapter is calling the toolbox, and therefore which budget applies.
public enum ToolProfile: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// FoundationModels on-device `Tool` conformers. Tiny budget, ≤ 5 tools.
    case onDevice
    /// A provider-agnostic agentic loop over AIConnectorKit.
    case cloud
    /// An in-process MCP server serving an external client.
    case external
}

/// Every hard limit the tool layer enforces, in one place. See the file header.
public enum ToolResultBudget {
    /// Characters a rendered ``ToolResult`` may occupy for ``ToolProfile/onDevice``.
    /// The HARD cap: rows are dropped until the whole result fits.
    public static let onDeviceCharacterLimit = 600
    /// Rows ``ToolProfile/onDevice`` renders before the "N more" suffix. A SOFT cap
    /// — ``onDeviceCharacterLimit`` can still drop rows below this.
    public static let onDeviceRowLimit = 10
    /// Characters one ``ToolProfile/onDevice`` row may occupy before it is elided.
    public static let onDeviceRowCharacterLimit = 60

    /// Characters a rendered ``ToolResult`` may occupy for ``ToolProfile/cloud``.
    public static let cloudCharacterLimit = 8 * 1024
    /// Rows ``ToolProfile/cloud`` renders before the "N more" suffix.
    public static let cloudRowLimit = 50
    /// Characters one ``ToolProfile/cloud`` row may occupy before it is elided.
    public static let cloudRowCharacterLimit = 200

    /// Characters a rendered ``ToolResult`` may occupy for ``ToolProfile/external``.
    public static let externalCharacterLimit = 16 * 1024
    /// Rows ``ToolProfile/external`` renders before the "N more" suffix.
    public static let externalRowLimit = 100
    /// Characters one ``ToolProfile/external`` row may occupy before it is elided.
    public static let externalRowCharacterLimit = 300

    /// LIBRARY tools ``ToolProfile/onDevice`` publishes. Apple's guidance is 3–5
    /// tools per session; five is the ceiling and this layer never exceeds it.
    public static let onDeviceToolLimit = 5

    /// CONTROL tools ``ToolProfile/onDevice`` adds on top of ``onDeviceToolLimit``
    /// when the composition root granted a playback seam.
    ///
    /// Three, not four, and the number was MEASURED rather than guessed —
    /// `SystemLanguageModel.tokenCount(for:)` over a real session's instructions
    /// entry, on macOS 26.5 where `contextSize` is 4096:
    ///
    ///     instructions alone                    143
    ///     + 5 library tools                     955   (23.3% of the window)
    ///     + 3 control tools                    1250   (30.5%)
    ///     + the control instruction line       1288   (31.4%)  <- SHIPPED
    ///     + queue_tracks as a fourth           1396   (34.1%)
    ///
    /// The prefix is billed on EVERY turn, so it is held under a third of the
    /// window; a fourth control definition crosses that line even before the
    /// instruction line is added. `queue_tracks` is the one left out because it is
    /// also a refinement of `play_tracks` — the same test `get_tracks` fails
    /// against `search_tracks`. `LibraryChatToolBudgetTests` re-measures this on
    /// every run that can.
    public static let onDeviceControlToolLimit = 3

    /// Upcoming queue entries a playback report names before it starts counting.
    ///
    /// Ten because that is `onDeviceRowLimit` — a control tool's answer is billed
    /// against the same window as a lookup's, and a queue preview that could
    /// outgrow a search result would be the wrong thing to spend it on.
    public static let playbackQueuePreviewLimit = 10

    /// Row ids a LOOKUP or PLAYBACK call may name — `get_tracks`,
    /// `get_track_features`, `match_tracks`, `play_tracks`, `queue_tracks`.
    ///
    /// A hundred because each of these either renders every id it is given or hands
    /// the whole list to the player, so a longer batch would be answered only half
    /// read. Deliberately NOT raised alongside ``proposalIdentifierLimit``: widening
    /// it would widen playback control, which is a different decision from letting a
    /// listener ask for a long playlist.
    public static let identifierBatchLimit = 100

    /// Row ids `propose_playlist` may name — the one tool with its own, higher
    /// ceiling.
    ///
    /// Five hundred because a proposal is an OFFER: it renders as rows in a review
    /// sheet the listener still has to approve, so length costs a scroll rather than
    /// a truncated answer. The figure lands exactly on
    /// `SmartPlaylistRules.maximumLimit`, the clamp `sample_tracks` already lowers
    /// into, so a filed proposal can never name more ids than the materialiser will
    /// honour — `LibraryToolboxProposalTests` pins that coupling.
    public static let proposalIdentifierLimit = 500

    /// Rows any single tool fetches from the database, whatever the caller asks
    /// for. Bounds the read itself, not just the render.
    public static let fetchLimit = 200

    /// Entries a stats result reports per facet (top tracks / artists / genres).
    public static let statsFacetLimit = 5

    /// The mark appended to a row that hit ``ToolProfile/rowCharacterLimit``.
    public static let ellipsis = "…"
}

public extension ToolProfile {
    /// The hard ceiling on a rendered result's total length.
    var characterLimit: Int {
        switch self {
        case .onDevice: ToolResultBudget.onDeviceCharacterLimit
        case .cloud: ToolResultBudget.cloudCharacterLimit
        case .external: ToolResultBudget.externalCharacterLimit
        }
    }

    /// The soft ceiling on how many rows are rendered.
    var rowLimit: Int {
        switch self {
        case .onDevice: ToolResultBudget.onDeviceRowLimit
        case .cloud: ToolResultBudget.cloudRowLimit
        case .external: ToolResultBudget.externalRowLimit
        }
    }

    /// The ceiling on one rendered row's length.
    var rowCharacterLimit: Int {
        switch self {
        case .onDevice: ToolResultBudget.onDeviceRowCharacterLimit
        case .cloud: ToolResultBudget.cloudRowCharacterLimit
        case .external: ToolResultBudget.externalRowCharacterLimit
        }
    }

    /// Whether this profile publishes only the highest-value subset of the tools.
    var restrictsToolCount: Bool {
        self == .onDevice
    }
}
