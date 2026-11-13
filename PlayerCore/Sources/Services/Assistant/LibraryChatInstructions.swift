// LibraryChatInstructions — the system instructions one chat session is built
// with.
//
// ── FLOOR-AVAILABLE FOR THE SAME REASON AS `instructionsText(locale:)` ────────
//
// ``AssistantLibraryContext/instructionsText(locale:)`` is pure and ungated so a
// token-budget test can measure the EXACT string production sends without building
// a session. This is that, for the chat tier — and it matters more here, because
// these instructions are billed against the 4096-token window on EVERY turn
// alongside all five tool definitions, for the whole life of the conversation.
// Every sentence below is paid for repeatedly; there are six of them for that
// reason.
//
// ── WHAT EACH LINE IS BUYING ─────────────────────────────────────────────────
//
// The grounding line ("only reference tracks the tools return") is the same rule
// the single-shot tier enforces structurally: that tier can only emit a
// `PlaylistQuerySpec` whose genres are validated against the real library, so it
// CANNOT invent a title. A chat tier writes free prose and has no such structural
// floor, so the rule has to be stated — it is the one line that must not be cut.
//
// It is SCOPED — "never invent a title or an artist AS BEING IN THIS LIBRARY" —
// and the last four words are load-bearing rather than decorative. Unscoped, that
// sentence and the music-knowledge permission below contradict each other inside a
// single prompt, and the model resolves the contradiction the safe way: it refuses.
// Measured, the refusal it produced was for "what is the greatest rock song of all
// time", a question about no library at all. The scope keeps BOTH claims true —
// name anything you know, claim only what a tool returned to be HERE.
//
// The `list_genres`-first line is the chat restatement of why that tool is in the
// `.onDevice` five at all (see `LibraryToolbox+Search.swift`): an exact
// `= ? COLLATE NOCASE` match against an invented spelling returns nothing, and a
// small model asked for "something jazzy" will invent one.
//
// The `propose_playlist` line exists because the tool FILES rather than writes.
// W1's result text already says "Nothing has been saved yet", but a model that
// only read the tool's DESCRIPTION before deciding what to promise the listener
// would have promised a saved playlist one turn earlier.
//
// The count line is the prose half of `propose_playlist`'s `target_count`
// argument: the schema lets the model DECLARE the number it was asked for, and the
// tool echoes a shortfall back rather than refusing it — but neither does anything
// until the model has been told that "twenty songs" is a quantity to honour rather
// than a mood. It is one sentence in BOTH tiers because it is the cheapest line
// here that changes an answer.
//
// The brevity line is a budget control, not a style preference: an answer this
// tier writes stays in the transcript and is re-billed on every subsequent turn.
//
// ── THE TIER SPLIT, AND WHY IT IS A PARAMETER RATHER THAN TWO FUNCTIONS ──────
//
// The on-device tier reads these instructions inside a 4096-token window that also
// holds eight tool definitions and the whole conversation; the measured headroom
// above the shipped prefix is TENS of tokens, not hundreds. A cloud tier has no
// such ceiling. So the richer guidance a connector can afford — iterate until the
// count is met, the playlist call order, do not re-type the list the app already
// renders, and the flag-gated web workflow — is added ONLY for `.cloud`/`.external`
// and is what `profile` selects.
//
// `profile` is REQUIRED, with no default, and the switch over it is exhaustive:
// the failure this split can have is a cloud-only line silently reaching the
// on-device window, which shows up as a session that condenses on turn one rather
// than as anything that looks like a bug. A defaulted tier would let a new call
// site acquire the wrong one by omission, and a fourth `ToolProfile` case would
// pick a tier by accident instead of failing to compile. There is deliberately no
// deprecated no-tier shim for the same reason — a second door into this function
// is a second way to get the tier wrong.
//
// `webWorkflowEnabled` defaults to FALSE and is honoured only on a rich tier. It
// names `match_tracks` and the `web_search`/`mcp__` web tools, and the ungranted-tool
// hazard the control line below documents applies to it verbatim: the flag is turned
// on by the composition root only once those tools are actually merged into the
// published list.
//
// `musicKnowledgeEnabled` defaults to FALSE, is honoured only on a rich tier — and
// is deliberately gated on the OPPOSITE thing. It follows the listener's SETTING,
// never the published tool list, because the two say different things: the web flag
// asks "can this model reach the web?", which only the tools can answer, while this
// one asks "may it speak from what it already knows?", which only the listener can.
// Deriving it from `webWorkflowEnabled` would relax the strict rules for every user
// who happens to run an MCP server with the setting switched off — silently, and for
// precisely the person who never asked for it. The two flags are therefore
// independent, and a test pins each direction.
//
// ── THE CONTROL LINE IS CONDITIONAL, AND IT WAS EARNED THE HARD WAY ──────────
//
// Without it a granted session SEARCHES for the track and then NARRATES — "Playing
// Aurora Drift by Nova Field" — having called nothing. Measured live on this host:
// `play_tracks` was reached in 2 of 6 turns, and the other four told the listener
// their music had started when it had not. That is the worst failure this feature
// can have, because the sentence is indistinguishable from success. The line
// therefore names the tools AND says the quiet part out loud ("do not just say you
// did it"), which is the clause the failure was actually about.
//
// It is passed as a FLAG rather than always present because an ungranted session
// does not publish those tools: instructing a model to call a tool it was never
// given is how a confident refusal-free hallucination gets taught. `canControlPlayback`
// comes from the same `LibraryToolboxContext.playback` that decides registration,
// so the sentence and the tool list cannot disagree.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// The instructions ``LibraryChatSession`` opens a conversation with.
public enum LibraryChatInstructions {
    /// - Parameter locale: The language the listener writes in. Named for the
    ///   model rather than inferred from the text, matching
    ///   ``AssistantLibraryContext/instructionsText(locale:)``.
    /// - Parameter profile: The tier that will read these instructions. Required
    ///   rather than defaulted: ``ToolProfile/onDevice`` is the only tier whose
    ///   window cannot afford the richer guidance, and a call site that acquired a
    ///   tier by omission would overrun it silently. See the file header.
    /// - Parameter canControlPlayback: Whether this caller was granted the playback
    ///   tools. Read from the SAME ``LibraryToolboxContext/playback`` that decides
    ///   registration, so the sentence and the published tool list agree.
    /// - Parameter webWorkflowEnabled: Whether web-search tools were merged into
    ///   this caller's published list. Ignored on ``ToolProfile/onDevice``, which
    ///   never sees them.
    /// - Parameter musicKnowledgeEnabled: Whether the listener has PERMITTED the
    ///   model to draw on what it already knows about music. Driven by the setting,
    ///   never by the tool list — see the file header. Ignored on
    ///   ``ToolProfile/onDevice``.
    public static func text(
        locale: Locale,
        profile: ToolProfile,
        canControlPlayback: Bool = false,
        webWorkflowEnabled: Bool = false,
        musicKnowledgeEnabled: Bool = false
    ) -> String {
        var lines = baseLines
        if carriesRichGuidance(profile) {
            lines.append(contentsOf: richLines(
                webWorkflowEnabled: webWorkflowEnabled,
                musicKnowledgeEnabled: musicKnowledgeEnabled
            ))
        }
        if canControlPlayback {
            lines.append(controlLine)
        }
        lines.append("Answer in at most three short sentences.")
        lines.append("The listener writes in \(locale.identifier).")
        return lines.joined(separator: "\n")
    }

    /// Whether `profile` can afford the lines in
    /// ``richLines(webWorkflowEnabled:musicKnowledgeEnabled:)``.
    ///
    /// Exhaustive on purpose — a new ``ToolProfile`` case must choose a tier here
    /// rather than inherit one from a `default`.
    private static func carriesRichGuidance(_ profile: ToolProfile) -> Bool {
        switch profile {
        case .onDevice: false
        case .cloud, .external: true
        }
    }

    /// The lines EVERY tier pays for, in publication order.
    private static let baseLines = [
        "You are the assistant inside MacAMP, a music player. "
            + "You answer questions about the listener's own music library.",
        "Use the tools to look things up. Only reference tracks, artists and genres the tools returned to you — "
            + "never invent a title or an artist as being in this library.",
        "Call list_genres before filtering by genre, so you use this library's own spelling.",
        "When the listener wants a playlist, call propose_playlist. For a genre or a long one, pass genre "
            + "and target_count, not track_ids. It saves nothing, so say it awaits approval.",
        "When the listener states how many tracks they want, propose exactly that many; "
            + "if you cannot, say how many you found.",
    ]

    /// The playback-grant sentence. See the file header.
    private static let controlLine =
        "To start, pause, skip or change what is playing, CALL play_tracks or transport — "
            + "never only say that you did it. Look the tracks up first and pass their ids."

    /// The guidance only a tier without the 4096-token ceiling can afford.
    ///
    /// Three lines always, plus two when the listener permitted the model's own
    /// music knowledge and three more when the web tools were merged: iterate until
    /// the requested count is met, the order the playlist calls go in, and the
    /// reminder that the app already renders every tool result as a track list — so
    /// re-typing one into the prose spends the answer twice.
    private static func richLines(webWorkflowEnabled: Bool, musicKnowledgeEnabled: Bool) -> [String] {
        var lines = [
            "Gather track ids in as few lookups as possible, up to 500: one sample_tracks call with genre "
                + "and year bounds at limit 50, or one search_tracks call at a large limit, beats many "
                + "small repeated searches. Never repeat a lookup you already made.",
            "For a playlist: call list_genres, gather ids with search_tracks and sample_tracks, then call "
                + "propose_playlist with target_count set to the number they asked for.",
            "Do not paste track lists into your prose — the app renders every tool result as a track list. "
                + "Summarize in one sentence instead.",
            "After filing a playlist proposal, end with one sentence: the playlist name, how many tracks "
                + "came from this library, and how many are suggestions beyond it.",
        ]
        if musicKnowledgeEnabled {
            lines.append(
                "You may use your own knowledge of music for songs beyond this library — always verify "
                    + "candidates with match_tracks before proposing."
            )
            lines.append("General music questions may be answered from your own knowledge or the web.")
        }
        if webWorkflowEnabled {
            lines.append(
                "For music that is not in this library, search the web with the web_search or mcp__ tools, "
                    + "pass what you found to match_tracks, then call propose_playlist with target_count."
            )
            lines.append(
                "The app renders tracks that are missing locally as links, so do not list them in your prose — "
                    + "say how many there are and move on."
            )
            lines.append("If no web tool is available, say so rather than guessing.")
        }
        return lines
    }
}
