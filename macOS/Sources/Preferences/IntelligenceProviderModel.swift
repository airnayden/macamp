// IntelligenceProviderModel — the Intelligence pane's view of ONE selected connector.
//
// The pane needs three things the settings store cannot answer: which connectors
// this build registered, whether the chosen one works right now, and which models
// it offers. All three come from a single `ConnectorRegistry.probe(id:)` — the
// kit's probe IS `listModels()`, so one round-trip fills the status row and the
// model picker together and leaves the UI nothing else to fetch.
//
// ── NO `.onChange`, AND NO SELF-DRIVEN REFRESH EITHER ──────────────────────────
//
// This model never observes settings and never schedules its own work. The section
// drives it from `.task(id: settings.selectedConnectorID)`, which starts on appear,
// restarts on a new selection, and CANCELS the outgoing probe — the three
// behaviours an `.onChange` pair would have to reproduce by hand. The pane's
// no-`.onChange` contract (the graph rebuild belongs to `AppEnvironment`'s
// `withObservationTracking`) therefore holds without this type knowing about it.
//
// ── ONE STORED PROPERTY, REPLACED WHOLE ────────────────────────────────────────
//
// `selection` is a single value, never a bag of `status` / `isProbing` / `id`
// fields mutated in sequence: a probe that returns after the listener has already
// picked a different provider must be DISCARDED, not partially applied. The
// generation check is `selection?.id == id` immediately after the await, which is
// the same "did the world move under me" test `.task(id:)` cancellation makes
// likely but does not guarantee.
import AIConnectorBridge
import AIConnectorKit
import Foundation
import Observation
import Services

/// The selected connector's live state, as the Intelligence pane sees it.
@Observable
@MainActor
final class IntelligenceProviderModel {
    /// What is known about the connector the listener currently has selected.
    struct Selection: Equatable {
        /// The connector's stable machine id — the value persisted in settings.
        let id: String
        /// The provider's own name. A BRAND: rendered verbatim, never localized.
        let displayName: String
        /// The last probe's answer, or `nil` while the first one is still running.
        var status: ConnectorStatus?
        /// Whether a probe is in flight right now.
        var isProbing: Bool
    }

    /// The connectors this build offers, in the order the picker lists them.
    ///
    /// Seeded from the LIVE registry the ladder routes through when the graph
    /// exists, so the picker cannot disagree with what actually answers.
    private(set) var registry: ConnectorRegistry

    /// The selected connector, or `nil` when Apple Intelligence is answering.
    private(set) var selection: Selection?

    init(registry: ConnectorRegistry = ConnectorRegistry()) {
        self.registry = registry
    }

    /// Adopts `registry`, then probes `connectorID` against it.
    ///
    /// ONE call rather than an `adopt` / `refresh` pair, so the section needs a
    /// single `.task(id:)` and no ordering assumption between two of them: a probe
    /// run before the registry landed would resolve every id to nothing and clear
    /// the selection the listener can plainly see in the picker.
    func reload(connectorID: String?, registry: ConnectorRegistry) async {
        self.registry = registry
        await refresh(connectorID: connectorID)
    }

    /// The models the last probe enumerated.
    ///
    /// `nil` and `[]` are DIFFERENT answers and the pane renders them differently:
    /// `nil` means no probe has listed anything yet (or the connector is not
    /// ready), `[]` means the provider genuinely offers none — a freshly installed
    /// Ollama with no model pulled.
    var reportedModels: [ModelInfo]? {
        selection?.status?.reportedModels
    }

    /// Probes `connectorID`, replacing ``selection`` with the result.
    ///
    /// Passing `nil` — or an id no build registered — clears the selection, which
    /// is how the Apple Intelligence default and a stale persisted id both resolve.
    func refresh(connectorID: String?) async {
        guard let identifier = connectorID,
              let descriptor = registry.descriptor(id: identifier)
        else {
            selection = nil
            return
        }
        selection = Selection(
            id: identifier,
            displayName: descriptor.displayName,
            status: selection?.id == identifier ? selection?.status : nil,
            isProbing: true
        )
        let probed = await descriptor.probe()
        // A newer refresh (or a cleared selection) took over while this one was in
        // flight — its answer is the current truth, so this one is dropped whole.
        guard selection?.id == identifier else { return }
        selection = Selection(
            id: identifier,
            displayName: descriptor.displayName,
            status: probed,
            isProbing: false
        )
    }
}

// MARK: - Active tier

/// Which tier the assistant would actually use, and therefore which state the
/// pane's status row must report.
///
/// The row used to speak only for Apple Intelligence. Once a connector is selected
/// that is the wrong answer twice over: a connector is precisely the thing that
/// still works on a Mac which cannot run the on-device model at all, and a working
/// connector beside "Apple Intelligence is unavailable" reads as a broken app.
enum IntelligenceActiveTier: Equatable {
    /// Nothing selected — the shipped default, on-device, zero network.
    case appleIntelligence(AssistantAvailability)
    /// A connector is selected; `status` is `nil` while the first probe runs.
    case connector(id: String, displayName: String, status: ConnectorStatus?)

    /// The tier in force. A selection wins over Apple Intelligence's availability
    /// WHENEVER one exists — including while its first probe is still running,
    /// because the request would already be routed there.
    init?(availability: AssistantAvailability?, selection: IntelligenceProviderModel.Selection?) {
        if let selection {
            self = .connector(id: selection.id, displayName: selection.displayName, status: selection.status)
            return
        }
        guard let availability else { return nil }
        self = .appleIntelligence(availability)
    }

    /// The provider's own name for the row's label, or `nil` for the on-device
    /// tier — whose label is localized copy rather than a brand.
    var providerName: String? {
        switch self {
        case .appleIntelligence: nil
        case let .connector(_, displayName, _): displayName
        }
    }

    /// The connector id, for the per-connector accessibility identifier.
    var connectorID: String? {
        switch self {
        case .appleIntelligence: nil
        case let .connector(id, _, _): id
        }
    }

    /// The sentence the row shows. Every path is catalog copy — a machine token
    /// from either taxonomy is mapped, never rendered.
    var message: LocalizedStringResource {
        switch self {
        case .appleIntelligence(.available):
            PreferencesStrings.intelligenceStatusAvailable
        case let .appleIntelligence(.unavailable(reason)):
            reason.message
        case .connector(_, _, .none):
            PreferencesStrings.intelligenceConnectorChecking
        case let .connector(_, _, .some(status)):
            PreferencesStrings.connectorStatusMessage(status)
        }
    }

    /// Whether the active tier can answer right now — what picks the row's glyph
    /// and tint. An unfinished probe is not yet healthy, and says so in copy.
    var isHealthy: Bool {
        switch self {
        case let .appleIntelligence(availability): availability.isAvailable
        case let .connector(_, _, status): status?.isReady ?? false
        }
    }

    /// Whether to add "requests are still matched without the language model".
    ///
    /// True whenever the active tier cannot answer, because the ladder really does
    /// fall through to the heuristic tier in that case — for a refused connector
    /// exactly as for an ineligible device. The ONE exception is the listener
    /// having switched the feature off themselves, which needs no consolation. A
    /// probe still running says nothing yet.
    var showsHeuristicFallbackNotice: Bool {
        switch self {
        case let .appleIntelligence(availability):
            guard case let .unavailable(reason) = availability else { return false }
            return reason != .intelligenceDisabled
        case let .connector(_, _, status):
            guard let status else { return false }
            return !status.isReady
        }
    }
}
