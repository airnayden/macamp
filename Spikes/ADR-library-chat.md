# ADR: Chat with your Library — LibraryToolbox, multi-turn chat, and MCP server

- **Status:** ACCEPTED
- **Date:** 2026-08-28
- **Deciders:** Owner (accepted at plan approval, W1–W5 waves executed)
- **Supersedes:** nothing; extends ADR-ai-provider-connectors.md (connect-time consent v1)

---

## Decision

MacAMP gains multi-turn conversational access to the music library through three
coordinated surfaces: a shared **LibraryToolbox** (ten named library tools, three
capability tiers), a **LibraryChatSession** actor for on-device Foundation Models
chat, and a **ConnectorChatEngine** path through `AIConnectorKit` for cloud
providers. A local **MCP server** (`macOS/Sources/MCP/`) exposes the same toolbox
to external agents over streamable HTTP on loopback.

All three surfaces share one rule: **nothing is written without explicit user
review.** The only write tool is `propose_playlist`, which files into the existing
`ProposalStore` that the existing `ProposalPreviewSheet` reviews. The review/apply
invariant from the original assistant is unchanged.

---

## Context

### The nine-field translator ceiling

The prior assistant (ADR-ai-provider-connectors.md) serialized the request into a
fixed nine-field payload — `genre`, `tempo`, `energy`, `decade`, and a handful of
extras — and handed that to the connector. The model had no agency over what it
looked at: it received a snapshot and returned a schema-shaped answer. This
collapsed the full richness of the library into a predetermined slice, made
follow-up impossible ("Which of those has more bass?" had no second turn to answer
it), and meant a connector's model was effectively executing a template, not
reasoning.

Multi-turn chat with tool access fixes all of this. The model can ask for what it
actually needs, refine based on results, and hold context across turns.

---

## The decisions

### 1. One toolbox, three tiers — not three separate implementations

A single `LibraryToolbox` instance publishes tools at a tier (`ToolProfile`) that
the calling path selects. The tier changes exactly two things: which tools are
published, and how much text a result may occupy. Nothing tier-specific lives
inside the tools themselves.

This means a schema change, a result format change, or a privacy fix propagates to
all three callers automatically. A separate per-tier implementation would create
three places to keep consistent.

The three tiers are `.onDevice` (5 tools, 600-char results), `.cloud` (all 10, 8 KB),
and `.external` (all 10, 16 KB). Constants live in `ToolResultBudget` — cite them,
don't restate them.

### 2. `.onDevice` publishes exactly five tools

The chosen five — `search_tracks`, `list_genres`, `sample_tracks`,
`get_listening_stats`, `propose_playlist` — are the smallest set that completes the
"make me a playlist" loop end to end. The four dropped tools (`get_tracks`,
`get_track_features`, `list_playlists`, `get_playlist`) are refinements; a sixth
tool definition costs 4096-token context on every turn of a compact model.
`ToolResultBudget.onDeviceToolLimit` is asserted at 5 so a future addition fails a
test rather than silently expanding the on-device surface.

### 3. Consent v2: library browsing is a separate, second record

The connect-time consent (v1) covered a fixed payload: 600 characters, 64 genres,
50 artists. A conversation is different: the model decides which tools to call and
how many times — nobody can enumerate in advance which rows will be read.

An existing v1 acceptance cannot cover v2. The two consents are independent:
`libraryBrowsingConsentedConnectorIDs: Set<String>` is the second record, keyed by
connector id. `LibraryChatConsentTests` pins all three values (consented / declined
/ neutral) through identical inputs and demands one answer.

**Declining is session-local, not persisted.** `chatDeclinedProviderID` is `@State`
on `AssistantView`. The sheet is not re-offered on every send (hostile) but
reappears when the user leaves the pane and returns (not "never"). Persisting a
decline was rejected because a listener who says "not now" has not said "never".

**Apple Intelligence is exempt by construction.** The routing matrix reaches the
consent branch only through `.connector`, so the on-device branch never reads the
record.

### 4. Consent v3: external access is a flag, not a set

The external access disclosure (`externalAccessConsented: Bool`) cannot be keyed by
connector id because the principal is an unnamed local process — MacAMP is told
nothing about who is connected. The sheet says this explicitly. A flag is the
honest shape.

This is a third record (`AppSettings.externalAccessConsented`). It is deliberately
not the same as v1 or v2: "this connector may browse inside a MacAMP conversation"
and "any program running as you can browse while this is on" are different promises.

### 5. Review/apply invariant: unchanged

`propose_playlist` files into `ProposalStore`. Nothing is applied until the user
opens the proposal in `ProposalPreviewSheet` and clicks Apply. There is no method
that submits and applies in one step.

The "Waiting for you" section (`AssistantView+PendingProposals.swift`) is additive:
it reads `ProposalStore.proposals` and surfaces pending proposals that have no
on-screen producer (reset chat, dismissed sheet, MCP-filed proposal). It opens the
existing sheet. It adds no write path.

### 6. Non-streaming v1

The cloud connector loop sends requests synchronously (one full `chatTurn` per
round), receives a complete response, runs the tool, and loops. Streaming would
require SSE parsing per connector and a streaming-aware transcript model. Deferred
to v2. The `ToolLoopEngine.defaultRoundDeadlineSeconds` (60 s) caps the worst-case
wait per round; `defaultMaxToolRounds` (20) caps total rounds.

### 7. The MCP swift-sdk dependency exception

`modelcontextprotocol/swift-sdk 0.12.1` (exact pin) is the first new third-party
dependency this repo has taken in a long time. The justification is that the
alternative is worse.

MCP is a versioned wire format. Hand-rolling it creates a permanent obligation to
re-implement a moving spec correctly against every client never tested against.
"Wrong" is silent: a spec-incorrect response may not error, just misbehave. The
official Swift SDK is written by the spec's own authors and is the artifact the
spec is validated against.

The cost is measured. The `MCP` target links only `swift-system`, `swift-log`, and
`eventsource`. `swift-nio`, `swift-atomics`, and `swift-collections` are in
`Tuist/Package.resolved` because SwiftPM resolves the whole manifest, but they
belong to the SDK's conformance executables and are never linked — `otool -L` on
the built app finds zero NIO images.

The SDK is wired to `macampMac` only.

### 8. `MCPSessionRegistry`: one (Server, transport) pair per session — **SUPERSEDED 2026-08-29**

**Original decision.** The SDK's `StatefulHTTPServerTransport` holds one session
id, refuses a second `initialize`, and sets `terminated` permanently on DELETE. A
server wired to one transport is bricked by its first clean disconnect (MCP
Inspector sends DELETE on quit). The registry mints a new pair per un-sessioned
`initialize`, capped at 8 sessions with LRU eviction. It was recorded as a
workaround to be deleted when the SDK shipped a stateless transport.

**Superseded.** `StatelessHTTPServerTransport` turned out to be present in the
pinned 0.12.1 all along, so no SDK upgrade was needed. `MCPSessionRegistry.swift`
is deleted; `MCPHTTPConnectionLoop` now gives each accepted TCP connection its own
(`Server`, `StatelessHTTPServerTransport`) pair. No `Mcp-Session-Id` is minted or
required, GET/DELETE answer 405, responses are plain JSON, and every POST is
self-contained. The framer, bridge, model, and settings were unaffected, exactly
as this entry predicted.

The pair is connection-scoped rather than one shared server, for two SDK
constraints read out of the pinned checkout: `Server`'s built-in `initialize`
handler refuses a second initialize regardless of `Configuration.strict`, and the
stateless transport keys its response waiters by the client's own JSON-RPC id, so
two concurrent clients both numbering a request `1` would collide. See
`.omo/evidence/library-chat/mcp-stateless.txt`.

### 9. `listChanged: false`

The registry publishes a fixed set of tools. A profile switch changes which rows the
tools return, not which tools exist. Declaring `listChanged: true` would promise a
notification that can never fire; a client may wait for one.

### 10. External access requires `intelligenceEnabled`

The only thing an external tool can write is a proposal. A proposal is reviewed in
the Assistant pane. The Assistant pane doesn't exist when Intelligence is off.
Serving tools whose write seam leads nowhere would be a dead end dressed as a
feature. All three external-access switches (`intelligenceEnabled`,
`externalAccessEnabled`, `externalAccessConsented`) are read in one place
(`MCPExternalAccessModel.apply`) so a second entry point cannot skip one.

---

## Consequences

- `LibraryToolbox` tool names are a wire format. Rename = breaking change for
  saved provider conversations AND external MCP clients simultaneously.
- The on-device tier is compact by design. Users with Apple Intelligence can chat
  about their library but may not get every library tool or full-depth results.
- The cloud tier's library-browsing scope is not fixed in advance — the model
  decides which tools to call. This is the structural reason v2 consent is a
  separate, second record.
- ~~`MCPSessionRegistry` is technical debt with a known resolution path. Monitor the
  SDK for `StatelessHTTPServerTransport` and delete the registry when it ships.~~
  **Discharged 2026-08-29** — the transport was already in the pin; the registry is
  deleted and the server is stateless (decision 8 above).
- `ChatGPT` non-streaming is empirically unverified in production — live QA drove
  curl and Inspector successfully but the connector's non-streaming response path
  has not been exercised with a live signed-in ChatGPT session.

---

## Evidence

- `.omo/evidence/library-chat/w3-fm-chat.txt` — live FM round-trip (macOS 26.5.1,
  `contextSize` 4096, tool call + profile-scoped visibility, two-turn statefulness).
- `.omo/evidence/library-chat/w4-chat-ui.txt` — W4 live UI verification (AX
  transcripts, responder access logs, consent flow, declined-and-fallthrough path).
- `.omo/evidence/library-chat/w5-mcp.txt` — W5 MCP server live QA (curl, Inspector,
  DELETE → re-initialize, privacy sweep over the wire, proposal → apply round-trip).

---

## Addendum — 2026-08-30

Two follow-up passes landed after the original decisions above were written and
accepted. Both extend the architecture without revising any earlier decision.

### Stateless MCP transport (commit `2818ec9`)

**Decision 8 is superseded in full.** `MCPSessionRegistry.swift` is deleted;
`MCPHTTPConnectionLoop` now owns one (`MCP.Server`, `StatelessHTTPServerTransport`)
pair per accepted TCP connection. The transport from the original decision
(`StatefulHTTPServerTransport`) is gone; the registry that existed to work around
its limitations is gone with it.

**What changed on the wire:**

- No `Mcp-Session-Id` is ever minted or required. Every POST is self-contained.
  `tools/list` is served on a fresh connection with no prior `initialize`.
- `GET` and `DELETE` return `405 Method Not Allowed` (`Allow: POST`). There is no
  SSE stream to open and no session to delete.
- Responses are plain `Content-Length`-framed JSON, not SSE frames. The
  `application/json, text/event-stream` pair every real client sends is accepted
  (`AcceptHeaderValidator(mode: .jsonOnly)` requires only that `application/json`
  be named).
- Version negotiation is unchanged: the server still supports
  `[2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05]` and negotiates down. Older
  clients interop without changes.

**Why connection-scoped pairs, not one shared server:** two SDK constraints read
from the pinned 0.12.1 checkout make a single shared pair unsafe. `Server`'s
built-in `initialize` handler refuses a second initialize (`-32600 Server is
already initialized`, not gated on `Configuration.strict`). `StatelessHTTPServerTransport`
keys its response waiters by the client's own JSON-RPC id with a plain assignment,
so two concurrent clients both numbering a request `1` would overwrite each
other's continuation. Driven live: 24 concurrent clients, all using `id: 1`,
24/24 correct in 0.68 s. Evidence: `.omo/evidence/library-chat/mcp-stateless.txt`.

**Consequences:** no session map, no cap, no eviction rule. The technical-debt
bullet in the original Consequences section is discharged.

### App-control tools (commits `b25168f`–`bd73415`)

Four new tools — `get_playback_state`, `play_tracks`, `queue_tracks`, `transport`
— extend the toolbox with immediate playback actions, gated by two independent
grants with different defaults.

**The control-tool category and its boundary.** Playback is ephemeral, local, and
reversible: pressing pause or picking a different track undoes any effect
immediately. No file is written, no setting is mutated, and no confirmation is
required. Settings mutation (EQ, theme, preferences) is permanently off-limits at
every tier — there is no tool that changes a MacAMP setting, and that boundary is
deliberate.

**Two grants, different defaults, different rationale:**

- `assistantPlaybackControlEnabled` (default **ON**). Typing "play it" into your
  own player's chat box is the instruction. Nothing leaves the machine; every
  effect is audible at once and undone by pressing pause. The off-switch exists
  for a read-only assistant; the setting caption states the default rather than
  hiding it.
- `externalAccessControlEnabled` (default **OFF**). A different and unnamed
  principal: MacAMP cannot identify which program connected. Reading metadata is
  quiet; taking the transport is not. Its own disclosure line, its own switch.

**Gating is "not registered", not "refuses".** A `nil`
`LibraryToolboxContext.playback` means the four tools are never built. They are
absent from every tier's published list and an ungranted call reads as an unknown
tool whose error message enumerates only the ten metadata tools. A model is never
shown a capability it would be refused, and cannot learn one exists from the error.

**FM instruction fix.** Before a conditional instruction line was added to
`LibraryChatInstructions`, a granted session searched for the track and then
narrated — "Playing Aurora Drift by Nova Field" — having called nothing.
`play_tracks` was reached in 2 of 6 turns; the other four told the listener their
music had started when it had not. One instruction line naming the failure ("never
only say that you did it") took it to 8 of 8. The line is conditional on the
grant, so an ungranted session is never instructed to call a tool it was not
given.

**On-device token budget.** The on-device context window is 4096 tokens; the
prefix is re-billed on every turn. Five library tools + three control tools +
the instruction line = 1288 tokens (31.4% of the window), staying under the
one-third ceiling. `queue_tracks` is the dropped tool — it is a refinement of
`play_tracks` exactly as `get_tracks` is of `search_tracks`, and adding it would
cross the ceiling. Cloud and external tiers have no such limit and publish all
four (14 in total). `LibraryChatToolBudgetTests` re-measures on every run so the
figure cannot go stale.

**Profile-visibility validation.** Every control tool resolves track IDs against
the active profile's `LibraryVisibility` predicate before touching the player. An
ID that is invisible (other profile's root) or missing from the library is refused
by name; a partially valid list plays what it can and names what it skipped.

Evidence: `.omo/evidence/library-chat/app-control-tools.txt`.
