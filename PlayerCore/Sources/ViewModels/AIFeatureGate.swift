// AIFeatureGate — the bridge from a per-bundle switch to an availability reading.
//
// The master toggle is a COMPOSITION decision: when it is off the shell builds no
// AI service at all, so there is nothing left to gate. A per-bundle switch is
// different — the service exists, the listener has simply turned one feature off —
// and it has to be enforced at the point of use, live, because flipping a bundle
// flag does not rebuild anything.
//
// ``AssistantViewModel`` already refuses every request whose availability reading
// is `.intelligenceDisabled`, and that refusal is the exact behaviour a disabled
// bundle needs: a typed error, no parse, no repository call, no database read. So
// rather than teach each view model a second switch to consult (two places for
// "off" to be implemented, one of which will eventually disagree), the bundle flag
// is folded INTO the availability probe the composition root injects.
//
// `AISettingsProviding.isEnabled(_:)` already ANDs the master toggle with the
// bundle flag, so a probe built here is off whenever EITHER is off.
import Foundation
import Services

/// Builds the availability probe a composition root injects for one feature bundle.
public enum AIFeatureGate {
    /// A probe reporting `.unavailable(reason: .intelligenceDisabled)` whenever
    /// `bundle` is switched off, and the real system reading otherwise.
    ///
    /// The returned closure reads `settings` on every call rather than capturing a
    /// snapshot, so toggling a bundle takes effect immediately — no rebuild, no
    /// relaunch, and no observer. `MainActor.assumeIsolated` is sound because every
    /// caller of the probe (`AssistantViewModel.submit`) is itself `@MainActor`.
    ///
    /// Takes `some AISettingsProviding & Sendable`, NOT the `any` existential this
    /// repo otherwise injects everywhere: `any AISettingsProviding` is not
    /// `Sendable` (the protocol does not refine it), while every conformer is — a
    /// `@MainActor` class is implicitly `Sendable`. Binding the opaque type is what
    /// lets the probe be `@Sendable` without touching the protocol's declaration.
    public static func availabilityProbe(
        for bundle: AIFeatureBundle,
        settings: some AISettingsProviding & Sendable
    ) -> @Sendable () -> AssistantAvailability {
        { @Sendable in
            MainActor.assumeIsolated {
                AssistantAvailabilityProbe.current(intelligenceEnabled: settings.isEnabled(bundle))
            }
        }
    }
}
