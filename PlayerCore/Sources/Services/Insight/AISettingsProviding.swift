// AISettingsProviding — the ONE declaration of the local-AI feature switches.
//
// Every AI capability in the app is gated by TWO booleans: the master toggle and
// the single bundle flag that owns the feature. This file is the only place that
// pair is declared. The shells' `AppSettings` types conform to it — they already
// store the values in `UserDefaults` — and nothing else in PlayerCore may restate
// it: a second declaration would let a shell satisfy one protocol while a service
// reads the other, and "off" would silently stop meaning off.
//
// `@MainActor` + `AnyObject`, matching every other shell-facing protocol in this
// module (``AudioAnalyzing``, ``LyricsSweeping``, ``ProfileManaging``). It is not
// a style choice: both conformers are `@MainActor @Observable public final class
// AppSettings`, and under Swift 6 strict concurrency a main-actor-isolated stored
// property cannot witness a nonisolated requirement. A nonisolated protocol here
// would simply not be conformable by the two types that must conform to it.
// Reading a flag from a nonisolated context stays possible — it is one `await`.
//
// The DEFAULTS live in each shell's `AppSettings`, not here; this file only says
// which switches exist. The shipped default is recorded in the plan: the master
// toggle ships ON with the free heuristic bundles active.
//
// NAMING: the plan calls the top-level switch the "master toggle"; the property is
// ``AISettingsProviding/intelligenceEnabled`` because SwiftLint's
// `inclusive_language` rule rejects the word "master" in a DECLARATION under
// `--strict`. Prose and accessibility identifiers may still say master; a
// property, method or type name may not. "Intelligence" also matches the
// Preferences tab the toggle lives on.
//
// PlayerCore portability: no imports at all — the surface is stdlib types only.

/// One user-facing group of AI features.
///
/// The six bundles are the granularity the Intelligence settings pane exposes, so
/// a listener can keep, say, auto-mixes while turning natural-language creation
/// off. `rawValue` is a stable identifier a settings key may be derived from.
public enum AIFeatureBundle: String, Sendable, CaseIterable, Codable {
    /// Natural-language playlist requests ("upbeat 90s rock").
    case nlCreation
    /// Standing generated mixes — the daypart auto-mix.
    case autoMixes
    /// Library organisation proposals (folder/playlist restructuring).
    case organization
    /// Rediscovery surfacing — forgotten favourites, never-played, throwbacks.
    case rediscovery
    /// Listening insights and their narrative.
    case insights
    /// Library hygiene — duplicates, genre inconsistency, missing metadata.
    case hygiene
}

/// The master toggle and the six per-bundle switches.
///
/// Read through ``isEnabled(_:)`` rather than the raw properties: it is the one
/// place "master off means everything off" is implemented.
@MainActor
public protocol AISettingsProviding: AnyObject {
    /// The master switch. When `false` no AI feature may run, read the database,
    /// or schedule work, whatever the per-bundle flags say.
    var intelligenceEnabled: Bool { get }

    /// Natural-language playlist creation (``AIFeatureBundle/nlCreation``).
    var nlCreationEnabled: Bool { get }

    /// Standing generated mixes (``AIFeatureBundle/autoMixes``).
    var autoMixesEnabled: Bool { get }

    /// Library organisation proposals (``AIFeatureBundle/organization``).
    var organizationEnabled: Bool { get }

    /// Rediscovery surfacing (``AIFeatureBundle/rediscovery``).
    var rediscoveryEnabled: Bool { get }

    /// Listening insights and narrative (``AIFeatureBundle/insights``).
    var insightsEnabled: Bool { get }

    /// Library hygiene analysers (``AIFeatureBundle/hygiene``).
    var hygieneEnabled: Bool { get }
}

public extension AISettingsProviding {
    /// Whether `bundle` may run right now — the master toggle **and** its own flag.
    func isEnabled(_ bundle: AIFeatureBundle) -> Bool {
        guard intelligenceEnabled else { return false }
        switch bundle {
        case .nlCreation: return nlCreationEnabled
        case .autoMixes: return autoMixesEnabled
        case .organization: return organizationEnabled
        case .rediscovery: return rediscoveryEnabled
        case .insights: return insightsEnabled
        case .hygiene: return hygieneEnabled
        }
    }
}
