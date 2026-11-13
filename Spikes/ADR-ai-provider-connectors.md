# ADR: AI Provider Connectors — Network Premise Reversal

- **Status:** ACCEPTED
- **Date:** 2026-08-21
- **Deciders:** Owner (accepted at plan approval, ai-provider-connectors TL;DR and Q1=a decision)
- **Supersedes:** the "NO network calls" Must-NOT in `.omo/plans/local-ai-playlists.md` (Scope, Out / Must-NOT-Have)

## Decision

**MacAMP's assistant surface gains opt-in AI provider connectors — Ollama, Claude API key,
OpenAI API key, and (in the non-App-Store projectM build only) subscription OAuth connectors
— that may send a capped payload to external endpoints.** The default stays fully local
(Apple Intelligence / heuristics / deterministic). A connect-time consent sheet disclosing the
exact payload budget must be dismissed before any non-local connector activates. All secrets
live exclusively in the Keychain. Subscription OAuth connectors are excluded from App Store
builds at link time, not by a compile flag. The local-ai-playlists plan's "NO network calls"
Must-NOT is explicitly reversed by this ADR, with the safeguards described here.

## Context

### (a) The reversed Must-NOT and its source plan

`.omo/plans/local-ai-playlists.md` recorded the following in its Scope section under
"OUT / Must-NOT-Have":

> NO bundled/downloaded models (MLX, llama.cpp, custom Core ML for this feature). NO network calls.

That plan was fully local by design: Foundation Models runs on-device at zero process-RAM cost
to the app, so network access added no value at that stage. The present plan
(ai-provider-connectors) adds value precisely by letting users who lack Apple Intelligence, or
who prefer a specific provider, route the assistant through an external endpoint. The reversal
is intentional and scoped — only the assistant's playlist-query path may make network calls,
only when the user has explicitly configured and consented to a connector, and the payload is
capped (see section b).

The premise reversal is also noted explicitly in the plan:

> `.omo/plans/ai-provider-connectors.md` (Scope, Premise reversal notice): "This plan
> deliberately reverses that under the ADR (todo 21) with explicit consent UX. The default
> (unconfigured) state stays fully local."

### (b) Decision — opt-in connectors, default-local, payload budget, consent model

**Default stays local.** With no connector configured, behavior is identical to the
local-ai-playlists baseline: AI code makes zero network calls. The Apple Intelligence →
heuristic → deterministic default ladder is preserved in full.

**Opt-in connectors.** The user selects a connector (Ollama, Claude API key, OpenAI API key,
or in the projectM build a subscription OAuth connector) in the Intelligence pane. Selecting a
connector does not immediately activate it.

**Connect-time consent sheet.** Before any non-local connector sends its first request, a
modal sheet appears disclosing exactly what may leave the device:

- user request text, capped at **≤ 600 characters**
- genre vocabulary, capped at **≤ 64 entries**
- artist aggregates, capped at **≤ 50 entries**
- total serialized request body, capped at **≤ 16 KiB**

The user must dismiss this sheet before the connector activates. Consent state is stored
app-wide. Dismissing the sheet is a one-time per-connector action; re-showing it when the
connector is reconfigured (new key, new host) is a UX decision for the implementing todo.

**Payload budget enforcement.** The four numbers above are canonical for this plan. They mirror
the existing Foundation Models cap (`FMAssistantBackend.maxRequestLength = 600`) and are
enforced in `AIConnectorBridge`'s `ConnectorPromptBuilder`, which truncates deterministically
(most-frequent entries kept) rather than erroring. A 5000-genre fixture test verifies that the
serialized body stays under 16 KiB with exactly 64 genres.

**Master and `.nlCreation` switches still hard-gate connectors.** `AIFeatureGate` folds
`settings.isEnabled(.nlCreation)` into `.intelligenceDisabled` and the `submit` path
hard-returns before `resolvedSpec` when `intelligenceEnabled == false`. This is preserved —
connectors bypass only the Apple Intelligence *capability* check, never the user's own
off-switches.

### (c) Link-time OAuth gate mechanism and targets

`AIConnectorKit/Package.swift` declares three SPM products:

| Product | Contents | Linked into |
|---|---|---|
| `AIConnectorKit` | protocols, transports, API-key connectors | `macampMac`, `macampMac-projectM` |
| `AIConnectorBridge` | seam conformers, canonical schema, prompt builder | `macampMac`, `macampMac-projectM` |
| `AIConnectorKitOAuth` | OAuth engines, subscription connectors | `macampMac-projectM` only |

In `macOS/Project.swift` the shared `appDependencies` list is split:

- `macampMac` links `AIConnectorKit` + `AIConnectorBridge`.
- `macampMac-projectM` links those two plus `AIConnectorKitOAuth`, and gains the additional
  buildable folder `macOS/ExternalOAuth/` for subscription login UI — mirroring the existing
  projectM precedent (`macOS/Project.swift:116-118,144-147`).

A compile flag `#if MACAMP_EXTERNAL_OAUTH` appears in shared shell code only as belt-and-braces
defense; it cannot gate SPM package code. The gate is therefore verified at the binary level:
`nm -gU` on `macampMac` must show zero OAuth symbols; `strings` corroborates. This check runs
in todo 20 and is the definitive link-gate proof.

**ToS-gray rationale for projectM-build-only restriction.** Claude and ChatGPT subscription
tiers are accessed through OAuth flows whose use in third-party apps is not formally authorized
by their providers. Shipping these connectors in an App Store build — where Apple reviews and
publicly distributes the app — creates meaningful ToS exposure. Restricting them to
`macampMac-projectM` (Developer ID, direct download, never App-Store-reviewed) keeps the
exposure in a channel where the user has consciously chosen a non-App-Store binary. The OAuth
code is never linked into any App Store target.

### (d) Keychain-only secrets

API keys, OAuth tokens, and refresh tokens are stored exclusively via `KeychainSecretStore`.
They never touch `AppSettings`, `UserDefaults`, app-group plists, logs, or evidence files.
`KeychainSecretStore` must NOT set `kSecUseDataProtectionKeychain` because `macampMac` is
currently unsandboxed — setting that attribute without the sandbox entitlement returns
`errSecMissingEntitlement (-34018)`. Config sheets use commit-on-Save semantics; keystrokes
never trigger Keychain writes.

### (e) Connector-owned availability — never `AssistantAvailability`

Each connector exposes its own `ConnectorStatus` predicate (`unconfigured` / `ready(models:)` /
`unreachable` / `authExpired` / `disabled(reason:)`). This predicate is evaluated independently
of `AssistantAvailability` / `AssistantAvailabilityProbe`, which probes Apple's
`SystemLanguageModel` and would silently kill connectors on any Mac without Apple Intelligence.
Connectors run on macOS 14+ regardless of Apple Intelligence availability — their availability
must flow through `ConnectorStatus`, never through `AssistantAvailability`.

### (f) App-wide (non-profile) scoping

Connector settings and Keychain secrets are app-wide, not per-profile. The rationale: Keychain
entries and `AppSettings` are not profile-scoped data structures; connector credentials belong
to the machine identity, not a listening profile. On profile switch, `rescopeAI`
(`macOS/Sources/AppEnvironment+AI.swift:214-221`) cancels any in-flight connector task — the
scoping boundary is enforced at the cancellation point, not at the credential store.

### (g) Known gaps — sandbox and network entitlements

**Current state (as of this ADR):** `macampMac` is NOT sandboxed. There is no
`com.apple.security.app-sandbox` entitlement in `macampMac.entitlements`. Connector network
calls use standard `URLSession` and succeed without sandboxing.

**Future App Store build requirements.** Any App Store submission of `macampMac` that ships
live connector functionality must add both of the following entitlements before submission:

- `com.apple.security.app-sandbox` — required for all App Store macOS apps.
- `com.apple.security.network.client` — required for any sandboxed app that opens outbound
  network connections.

Neither entitlement is present today. Failing to add them will cause `URLSession` calls to fail
silently inside the sandbox, with no crash and no visible error — the connector will appear to
hang indefinitely.

### (h) Encryption declaration — `ITSAppUsesNonExemptEncryption: false` re-confirmed

`iOS/Project.swift:28` declares `"ITSAppUsesNonExemptEncryption": false`. This value covers
the iOS build and applies equally to any future App Store macOS build that ships connector code.

The connectors introduced by this plan use:

- **TLS (HTTPS)** — all API communication travels over TLS 1.2+. TLS uses publicly specified,
  industry-standard algorithms (AES-GCM, ChaCha20, ECDHE) implemented entirely by
  Security.framework with no custom cryptographic code.
- **OAuth 2.0 PKCE** — the subscription OAuth flows use PKCE. PKCE's code-challenge is a
  SHA-256 hash of a random verifier; SHA-256 is a publicly available, NIST-standardized
  algorithm, also provided by CryptoKit/Security.framework. No proprietary cipher is introduced.

Both qualify for the **standard encryption exemption** under US Export Administration
Regulations (EAR) Category 5, Part 2, Note 4 — "publicly available" cryptography used
exclusively for authentication and data-in-transit confidentiality, with no custom algorithm
implementation. Under Apple's guidance for this exemption, an app may declare
`ITSAppUsesNonExemptEncryption = NO` when it uses only standard, OS-provided cryptography for
these purposes, and does not implement, export, or redistribute custom cryptographic algorithms.
TLS and PKCE satisfy this test. No ERN (Encryption Registration Number) filing is required.

The declaration therefore remains `false` unchanged.

## Consequences

- **Todo 1 (AIConnectorKit scaffold):** `macOS/Project.swift` splits `appDependencies` — both
  targets link `AIConnectorKit`+`AIConnectorBridge`; `macampMac-projectM` additionally links
  `AIConnectorKitOAuth` and adds `macOS/ExternalOAuth/` as a buildable folder.
- **Todo 6 (canonical schema + prompt builder):** payload budget (≤ 600 chars, ≤ 64 genres,
  ≤ 50 artists, ≤ 16 KiB) is enforced in `ConnectorPromptBuilder`; the 5000-genre fixture
  test verifies deterministic truncation.
- **Todo 13 (macOS composition):** connect-time consent sheet must appear and be dismissed
  before the first non-local request; consent is app-wide, not per-profile.
- **Todo 20 (link-gate verification):** `nm -gU` + `strings` on both app binaries confirms
  `AIConnectorKitOAuth` symbols are absent from `macampMac` and present in `macampMac-projectM`.
- **Future App Store build:** must add `com.apple.security.app-sandbox` +
  `com.apple.security.network.client` before submitting any build that ships connector code.
- **iOS:** no changes to the iOS shell; `ITSAppUsesNonExemptEncryption: false` at
  `iOS/Project.swift:28` remains correct — TLS and PKCE are standard-crypto-exempt.

## Evidence

- Source Must-NOT: `.omo/plans/local-ai-playlists.md` (Scope, "OUT / Must-NOT-Have")
- Premise reversal notice: `.omo/plans/ai-provider-connectors.md` (Scope, final paragraph)
- Architecture notes (binding): `.omo/plans/ai-provider-connectors.md` (Architecture notes)
- Encryption key source: `iOS/Project.swift:28`
- Read-verification quotes: `.omo/evidence/ai-provider-connectors/todo-21-adr.txt`
- Audio engine ADR (format precedent): `Spikes/ADR-audio-engine.md`
- Karaoke separation ADR (format precedent): `Spikes/ADR-karaoke-separation.md`

---

## Superseded in part — 2026-08-22 (single-target merge)

The following aspects of this ADR are superseded by the single-target merge (commits
`3475ee3`..`00af4bd`). The original decision text is preserved above as a historical
record.

**App Store distribution permanently abandoned.** MacAMP will never be submitted to
the App Store. The "excluded from App Store builds at link time" rationale for the
`AIConnectorKitOAuth` link-gate no longer applies — there is no App Store build.

**Link-time gate retired; iOS-only assertion survives.** `macampMac-projectM` no
longer exists as a target. All three products (`AIConnectorKit`, `AIConnectorBridge`,
`AIConnectorKitOAuth`) are linked into the single `macampMac` target. The `nm -gU`
gate described in section (c) and todo 20 is retired. The surviving assertion is
`scripts/check-ios-oauth-linkage.sh`, run in the `portability-guard` CI job,
which asserts that `macampiOS` does not link any OAuth product.

**Single-target consequence.** The `appDependencies` split described in section (c)
("`macampMac` links `AIConnectorKit` + `AIConnectorBridge`; `macampMac-projectM`
additionally links `AIConnectorKitOAuth`") is superseded. `macOS/Project.swift` now
has one `appDependencies` list that includes all three products.

**OAuth ToS-gray caution now carried by documentation.** The rationale in section
(c) — restricting subscription OAuth connectors to a non-App-Store binary as a ToS
exposure mitigation — is now carried by documentation and user awareness rather than
build separation. The OAuth connectors remain opt-in and consent-gated as designed.

**Section (g) sandboxing note remains future work.** MacAMP is still unsandboxed.
`com.apple.security.network.client` is present in the entitlements file and is
harmless today; `com.apple.security.app-sandbox` is not. This note is updated to
reflect that the App Store is not a target channel, but the sandboxing work may
still be wanted for hardening if the app is ever submitted elsewhere.
