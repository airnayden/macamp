// ConnectorRegistry — the ordered list of connectors THIS BUILD offers.
//
// ── THE REGISTRY KNOWS NO PROVIDER NAMES ───────────────────────────────────────
//
// There is no `case ollama` here, no `if id == "anthropic"`, and no built-in list.
// The app registers concrete instances at composition time, which is what makes
// two facts expressible at once: the App Store build registers three connectors
// and the non-App-Store build registers five, from the SAME type, with no
// conditional compilation inside the kit — and a subscription connector whose
// engine is not linked simply never registers, so a persisted selection pointing
// at it resolves to nothing rather than to a half-present feature.
//
// It is also what lets this whole target lift into another app: a registry that
// hardcoded MacAMP's three providers would be MacAMP's registry, not a kit's.
//
// ── ORDER IS THE UI'S ORDER ────────────────────────────────────────────────────
//
// An array, not a dictionary. Registration order is the order the settings picker
// lists connectors in, so it is a contract, not an implementation detail — and it
// survives re-registration (see ``register(_:disabledReason:)``) precisely so a
// rebuilt graph does not reshuffle the listener's picker.
import Foundation

/// One registered connector, plus whether this build will let it run.
///
/// The ``disabledReason`` is what turns "we could not ship this" into a state the
/// UI can render honestly. A disabled descriptor keeps its connector — the picker
/// still shows the provider, greyed, with a mapped explanation — rather than
/// vanishing and leaving the listener to wonder where it went.
public struct ConnectorDescriptor: Sendable {
    /// The instance the app built. `ConnectorProbing` is required, not optional:
    /// everything the registry holds must be answerable, and a conformer that has
    /// no cheaper truth gets the default probe for free.
    public let connector: any AIProviderConnector & ConnectorProbing

    /// A machine-readable token from ``ConnectorStatus/DisabledReason``, or `nil`
    /// when the connector is live. NEVER user-facing copy — the shell maps it.
    public let disabledReason: String?

    public init(
        _ connector: any AIProviderConnector & ConnectorProbing,
        disabledReason: String? = nil
    ) {
        self.connector = connector
        self.disabledReason = disabledReason
    }

    /// The connector's stable machine id — the value persisted in settings.
    public var id: String {
        connector.id
    }

    /// The provider's own name. NOT localized: a brand, like the MacAMP brand.
    public var displayName: String {
        connector.displayName
    }

    /// Which credential this connector needs. Metadata only.
    public var authDescriptor: AuthDescriptor {
        connector.authDescriptor
    }

    /// This connector's state now.
    ///
    /// A disabled descriptor answers WITHOUT calling its connector, so a probe
    /// costs nothing at all — no credential read, no transport call. That is the
    /// same "an unusable connector must not spend a round-trip" rule an
    /// unconfigured connector follows, applied one layer up.
    public func probe() async -> ConnectorStatus {
        if let disabledReason {
            return .disabled(reason: disabledReason)
        }
        return await connector.probe()
    }
}

/// One connector's probe outcome, tagged with which connector it belongs to.
///
/// A named pair rather than a tuple so it can cross into a view model and be
/// diffed there.
public struct ConnectorProbeResult: Sendable, Equatable {
    public let id: String
    public let status: ConnectorStatus

    public init(id: String, status: ConnectorStatus) {
        self.id = id
        self.status = status
    }
}

/// The connectors this build offers, in the order it offers them.
///
/// A value type: the composition root builds one, hands out copies, and a settings
/// change rebuilds it rather than mutating a shared instance — which is what keeps
/// an in-flight probe from observing a half-applied change.
public struct ConnectorRegistry: Sendable {
    /// Every registered connector, in registration order.
    public private(set) var descriptors: [ConnectorDescriptor]

    /// An empty registry — what a build that links no connectors ends up with, and
    /// a state the selection resolver is required to handle.
    public init() {
        descriptors = []
    }

    public init(_ descriptors: [ConnectorDescriptor]) {
        self.descriptors = []
        for descriptor in descriptors {
            register(descriptor)
        }
    }

    /// The registered ids, in order.
    ///
    /// This is the collection a persisted selection is resolved against, so an id
    /// no build registers degrades to "no connector" instead of to a dangling
    /// reference.
    public var ids: [String] {
        descriptors.map(\.id)
    }

    public var isEmpty: Bool {
        descriptors.isEmpty
    }

    /// Registers a connector, optionally marked disabled.
    ///
    /// - Parameter disabledReason: A ``ConnectorStatus/DisabledReason`` token, or
    ///   `nil` for a live connector.
    public mutating func register(
        _ connector: any AIProviderConnector & ConnectorProbing,
        disabledReason: String? = nil
    ) {
        register(ConnectorDescriptor(connector, disabledReason: disabledReason))
    }

    /// Registers a descriptor, replacing any existing one with the same id
    /// IN PLACE.
    ///
    /// Last registration wins, and it wins at the earlier position. Appending a
    /// duplicate would list one provider twice; dropping the newer one would make
    /// a rebuilt connector silently ignored. Replacing in place is the only
    /// behaviour that keeps both the picker's order and the caller's intent.
    public mutating func register(_ descriptor: ConnectorDescriptor) {
        if let existing = descriptors.firstIndex(where: { $0.id == descriptor.id }) {
            descriptors[existing] = descriptor
        } else {
            descriptors.append(descriptor)
        }
    }

    /// The descriptor registered under `id`, or `nil` when nothing is.
    public func descriptor(id: String) -> ConnectorDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// The connector registered under `id` — what the bridge wraps to build a
    /// parser or a namer.
    public func connector(id: String) -> (any AIProviderConnector)? {
        descriptor(id: id)?.connector
    }

    /// Probes one connector. `nil` means nothing is registered under `id`, which
    /// is a different answer from any status and must not be flattened into one.
    public func probe(id: String) async -> ConnectorStatus? {
        guard let descriptor = descriptor(id: id) else { return nil }
        return await descriptor.probe()
    }

    /// Probes every registered connector CONCURRENTLY, returning results in
    /// registration order.
    ///
    /// Concurrent because the settings pane shows all of them at once and three
    /// serial probes would take three deadlines to fail; ordered because the pane
    /// renders them in the picker's order, and completion order is whatever the
    /// network decided. Each probe carries its own deadline, so a wedged provider
    /// delays this call by one budget, not by one per connector.
    public func probeAll() async -> [ConnectorProbeResult] {
        let pending = descriptors
        return await withTaskGroup(of: (Int, ConnectorProbeResult).self) { group in
            for (index, descriptor) in pending.enumerated() {
                group.addTask {
                    await (index, ConnectorProbeResult(id: descriptor.id, status: descriptor.probe()))
                }
            }
            var ordered = [ConnectorProbeResult?](repeating: nil, count: pending.count)
            for await (index, result) in group {
                ordered[index] = result
            }
            return ordered.compactMap(\.self)
        }
    }
}
