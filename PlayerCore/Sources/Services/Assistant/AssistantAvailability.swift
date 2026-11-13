// AssistantAvailability — whether the on-device assistant can run right now.
//
// Modeled on `SeparationAvailability` (PlayerCore/Sources/Separation/SeparationAvailability.swift):
// two cases, `.available` and `.unavailable(reason:)`, where the reason is a plain
// associated-value-free enum carrying a `LocalizedStringResource` message. The UI can
// therefore explain WHY the assistant is off and tests can assert the exact cause.
//
// ── THE TWO-LAYER AVAILABILITY CONSTRAINT (read before touching this file) ──────
//
// `@available(macOS 26, iOS 26, *)` / `if #available` IS MANDATORY on every
// FoundationModels declaration and call site (a compiler/weak-linking requirement)
// — but it MUST NEVER be used as a capability proxy. Capability is decided ONLY by
// `SystemLanguageModel.default.availability`. Both layers are required; neither
// substitutes for the other.
//
// Concretely: `if #available(macOS 26, *)` merely lets us COMPILE and reach a
// reference to the FM types. It says NOTHING about whether the on-device model is
// actually eligible, enabled, or downloaded — that is a SEPARATE runtime question,
// answered only by `SystemLanguageModel.default.availability`. A build that treats
// the first as an answer to the second ships a feature that throws on every
// Apple-Intelligence-disabled machine.
//
// ── WHY FIVE REASONS WHEN APPLE HAS THREE ──────────────────────────────────────
//
// `SystemLanguageModel.Availability.UnavailableReason` has EXACTLY three cases —
// `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`. This
// module maps those 1:1 and adds TWO reasons of its own, which have no Apple
// counterpart because they are answered before the framework is reachable at all:
//
//   • `osTooOld`               — the running OS predates macOS 26 / iOS 26, so the
//                                FM types cannot even be referenced. A RUNTIME
//                                condition (an `if #available` that evaluates
//                                false), not a compile-time one.
//   • `intelligenceDisabled`   — the user's own master switch,
//                                ``AISettingsProviding/intelligenceEnabled``, is
//                                off. A product-level gate that outranks whatever
//                                the system reports.
//
// NAMING: the plan calls that switch the "master toggle". The declaration here is
// ``intelligenceDisabled`` because SwiftLint's `inclusive_language` rule rejects
// "master" in a DECLARATION under `--strict` — the same rename that produced
// ``AISettingsProviding/intelligenceEnabled``.
//
// ── WHY THE MAPPING IS PURE ────────────────────────────────────────────────────
//
// ``AssistantAvailability/resolve(raw:intelligenceEnabled:)`` is floor-available
// (macOS 14 / iOS 17), carries NO `@available` attribute, and never mentions a
// FoundationModels type. It runs on ``RawModelAvailability`` — this module's own
// four-state mirror of Apple's enum — so every one of the five outcomes, including
// the two that no machine in CI can produce, is directly table-testable. The single
// call site that touches the real system API lives in
// ``AssistantAvailabilityResolver``, behind `#if canImport(FoundationModels)` +
// `@available`, and does nothing but translate and delegate.
import Foundation

/// Whether the on-device assistant is usable in the current OS/session/settings.
///
/// Callers gate every assistant feature on this before attempting a
/// ``NaturalLanguageQueryParsing``, ``PlaylistNaming`` or ``InsightNarrating``
/// call. `.available` means the model is reachable and the user has opted in;
/// `.unavailable` explains why it is not.
public enum AssistantAvailability: Sendable, Equatable {
    /// The on-device model is reachable and the user has Intelligence enabled.
    case available
    /// The assistant cannot run; `reason` explains why (for UI + diagnostics).
    case unavailable(reason: AssistantUnavailableReason)

    /// `true` only in the `.available` case — a convenience for gating UI/logic
    /// without pattern-matching. Mirrors ``SeparationAvailability/isAvailable``.
    public var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    /// The pure, floor-available mapping from a raw system reading to this type.
    ///
    /// Deliberately carries no `@available` attribute and no FoundationModels
    /// reference, so it is unit-testable on any host — including the `osTooOld`
    /// branch, which no macOS 26 machine can otherwise reach.
    ///
    /// PRECEDENCE: the user's own switch is checked FIRST. A listener who turned
    /// Intelligence off is told exactly that, whatever the system would have
    /// reported — the product gate outranks the platform gate.
    ///
    /// - Parameters:
    ///   - raw: The system's reading, or `nil` when it could not be taken at all
    ///     (the OS predates macOS 26 / iOS 26, or FoundationModels was not in the
    ///     SDK this build compiled against).
    ///   - intelligenceEnabled: ``AISettingsProviding/intelligenceEnabled``.
    public static func resolve(
        raw: RawModelAvailability?,
        intelligenceEnabled: Bool
    ) -> AssistantAvailability {
        guard intelligenceEnabled else {
            return .unavailable(reason: .intelligenceDisabled)
        }
        guard let raw else {
            return .unavailable(reason: .osTooOld)
        }
        switch raw {
        case .available:
            return .available
        case .deviceNotEligible:
            return .unavailable(reason: .deviceNotEligible)
        case .appleIntelligenceNotEnabled:
            return .unavailable(reason: .appleIntelligenceNotEnabled)
        case .modelNotReady:
            return .unavailable(reason: .modelNotReady)
        }
    }
}

/// The typed reason the assistant is unavailable.
///
/// Kept associated-value-free so ``AssistantAvailability`` stays trivially
/// `Equatable`/`Hashable`; the localized, user-facing explanation is a computed
/// ``message``. This is a REPO-INTERNAL enum, so every switch over it must be
/// exhaustive with no `default:` — a sixth reason has to break the build.
public enum AssistantUnavailableReason: Sendable, Equatable, Hashable, CaseIterable {
    /// Maps `SystemLanguageModel.Availability.UnavailableReason.deviceNotEligible`
    /// — the hardware cannot run the on-device model.
    case deviceNotEligible
    /// Maps `…UnavailableReason.appleIntelligenceNotEnabled` — capable hardware,
    /// but the user has not switched Apple Intelligence on in System Settings.
    case appleIntelligenceNotEnabled
    /// Maps `…UnavailableReason.modelNotReady` — the system is still downloading
    /// or preparing model assets. Transient; retrying later can succeed.
    case modelNotReady
    /// App-specific: the running OS predates macOS 26 / iOS 26, so the
    /// FoundationModels types are not reachable. Detected at RUNTIME by an
    /// `if #available` that evaluates false — never by a compile-time branch.
    case osTooOld
    /// App-specific: the user's own Intelligence master switch
    /// (``AISettingsProviding/intelligenceEnabled``) is off.
    case intelligenceDisabled
    /// App-specific: the Apple Intelligence tier has been retired
    /// (``AppleIntelligenceRetirement/isRetired``). Requests fall through to a
    /// selected connector, or to the heuristic tier when none is selected.
    case retired

    /// The user-facing explanation, resolved through the shells' String Catalogs.
    public var message: LocalizedStringResource {
        switch self {
        case .deviceNotEligible:
            AssistantAvailabilityStrings.unavailableDeviceNotEligible
        case .appleIntelligenceNotEnabled:
            AssistantAvailabilityStrings.unavailableAppleIntelligenceNotEnabled
        case .modelNotReady:
            AssistantAvailabilityStrings.unavailableModelNotReady
        case .osTooOld:
            AssistantAvailabilityStrings.unavailableOSTooOld
        case .intelligenceDisabled:
            AssistantAvailabilityStrings.unavailableIntelligenceDisabled
        case .retired:
            AssistantAvailabilityStrings.unavailableRetired
        }
    }
}

/// A minimal, floor-available mirror of `SystemLanguageModel.Availability`.
///
/// Exactly four states: Apple's `.available` plus its three — and only three —
/// `UnavailableReason` cases. This type exists so the mapping logic above needs no
/// `@available` attribute and no FoundationModels import, which is what makes the
/// gate table-testable on hosts that cannot run the real model.
///
/// It is NOT a public settings surface: production code obtains a value only from
/// ``AssistantAvailabilityResolver``. Tests construct one directly.
public enum RawModelAvailability: Sendable, Equatable, Hashable, CaseIterable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
}

/// The floor-available entry point every caller should use.
///
/// Performs BOTH layers in the one place that is allowed to conflate them:
/// the `#if canImport` + `if #available` compile/OS layer, and — only when that
/// passes — the real capability query. Everything else in the app takes the
/// resulting ``AssistantAvailability`` and never re-derives it.
public enum AssistantAvailabilityProbe {
    /// The assistant's availability right now.
    ///
    /// While ``AppleIntelligenceRetirement/isRetired`` is `true` the on-device model is
    /// never reported available: the master switch still wins (so a disabled feature
    /// keeps its `.intelligenceDisabled` refusal), and otherwise the answer is
    /// `.retired`, which every caller already treats as "use the next tier".
    ///
    /// - Parameter intelligenceEnabled: ``AISettingsProviding/intelligenceEnabled``.
    public static func current(intelligenceEnabled: Bool) -> AssistantAvailability {
        if AppleIntelligenceRetirement.isRetired {
            return intelligenceEnabled ? .unavailable(reason: .retired) : .unavailable(reason: .intelligenceDisabled)
        }
        #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                return AssistantAvailabilityResolver.current(intelligenceEnabled: intelligenceEnabled)
            }
            // Compiled against a macOS 26 / iOS 26 SDK, but RUNNING on an older OS.
            return AssistantAvailability.resolve(raw: nil, intelligenceEnabled: intelligenceEnabled)
        #else
            // The SDK this build compiled against has no FoundationModels at all.
            return AssistantAvailability.resolve(raw: nil, intelligenceEnabled: intelligenceEnabled)
        #endif
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    /// The ONLY code in the app that touches `SystemLanguageModel`.
    ///
    /// Translates the system's resilient enum into ``RawModelAvailability`` and
    /// delegates to the pure mapper. Both `switch`es carry `@unknown default:` —
    /// the sanctioned carve-out from this repo's no-`default:` rule, which applies
    /// to REPO-INTERNAL enums; a resilient SYSTEM enum may gain a case in any OS
    /// update and must degrade rather than fail to compile. An unrecognised reason
    /// is treated as ``AssistantUnavailableReason/modelNotReady``: the only one of
    /// the three that invites a retry, so an unknown future state degrades to
    /// "try again" rather than to a permanent "your device can't do this".
    @available(macOS 26, iOS 26, *)
    public enum AssistantAvailabilityResolver {
        /// Reads `SystemLanguageModel.default.availability` and maps it.
        ///
        /// - Parameter intelligenceEnabled: ``AISettingsProviding/intelligenceEnabled``.
        public static func current(intelligenceEnabled: Bool) -> AssistantAvailability {
            AssistantAvailability.resolve(
                raw: rawAvailability(),
                intelligenceEnabled: intelligenceEnabled
            )
        }

        private static func rawAvailability() -> RawModelAvailability {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return .deviceNotEligible
                case .appleIntelligenceNotEnabled:
                    return .appleIntelligenceNotEnabled
                case .modelNotReady:
                    return .modelNotReady
                @unknown default:
                    return .modelNotReady
                }
            @unknown default:
                return .modelNotReady
            }
        }
    }
#endif

// MARK: - Apple Intelligence retirement

/// DEPRECATED TIER — Apple Intelligence (FoundationModels) is being removed from MacAMP.
///
/// The on-device tier is switched off here and nowhere else: while `isRetired` is
/// `true`, ``AssistantAvailabilityProbe`` never reports the model available, the
/// macOS composition root builds no FoundationModels parser, namer or narrator, and
/// the Intelligence pane no longer offers Apple Intelligence as a provider. Requests
/// go to the selected connector, or fall back to the heuristic matcher.
///
/// The FoundationModels code (`FMAssistantBackend`, `FMPlaylistNaming`,
/// `FMInsightNarrator`, `LibraryChatSession` and the `FM*` DTOs) is intentionally left
/// in place but is dead code while this flag is set. It will be deleted, together with
/// this flag and ``AssistantUnavailableReason/retired``, in a future release.
public enum AppleIntelligenceRetirement {
    /// `true` once Apple Intelligence can no longer be selected or used.
    public static let isRetired = true
}
