// MCPExternalAccessModel — the one thing that decides whether the port is open.
//
// Three switches have to agree, and they are checked in ONE place so a second
// entry point cannot be added that skips one:
//
//   1. `intelligenceEnabled` — a filed proposal is reviewed in the Assistant pane,
//      which does not exist when the master switch is off. Serving tools whose
//      only write seam leads somewhere unreachable would be a dead end dressed up
//      as a feature.
//   2. `externalAccessEnabled` — the listener's own switch, off by default.
//   3. `externalAccessConsented` — the disclosure, accepted once. Declining leaves
//      (2) off, so this is belt-and-braces behind the sheet's own gate, exactly the
//      discipline `makeChatEngine` applies to the browsing consent (W4 note 10).
//
// Reconciliation is SERIALISED through one task chain. Toggling quickly, or
// changing the port while it is coming up, otherwise races a `start` against a
// `stop` and can leave a listener bound with nothing pointing at it.
import Foundation
import Observation
import Services

@MainActor
@Observable
final class MCPExternalAccessModel {
    private(set) var status: MCPServerStatus = .stopped

    @ObservationIgnored private let server: any MCPExternalAccessServing
    @ObservationIgnored private let source: MCPToolboxSource
    @ObservationIgnored private var desiredPort: Int?
    @ObservationIgnored private var reconciliation: Task<Void, Never>?

    /// - Parameter toolbox: read at CALL time, never captured, so a profile switch
    ///   is visible to a connected client on its very next `tools/call`.
    init(
        server: any MCPExternalAccessServing = MCPLibraryServer(),
        toolbox: @escaping @Sendable () async -> LibraryToolbox?
    ) {
        self.server = server
        source = MCPToolboxSource(currentToolbox: toolbox)
    }

    func apply(settings: AppSettings) {
        let shouldServe = settings.intelligenceEnabled
            && settings.externalAccessEnabled
            && settings.externalAccessConsented
        reconcile(toward: shouldServe ? settings.externalAccessPort : nil)
    }

    func shutDown() {
        reconcile(toward: nil)
    }

    /// Awaits whatever the model is currently doing. Tests need it; nothing in the
    /// app does, because every caller is fire-and-forget by design.
    func settle() async {
        await reconciliation?.value
    }

    private func reconcile(toward port: Int?) {
        desiredPort = port
        let inFlight = reconciliation
        reconciliation = Task { [weak self] in
            await inFlight?.value
            await self?.step()
        }
    }

    private func refreshStatus() async {
        await reconciliation?.value
        status = await server.status
    }

    private func step() async {
        await server.setFailureHandler { [weak self] in
            await self?.refreshStatus()
        }
        guard let port = desiredPort else {
            await server.stop()
            status = .stopped
            return
        }
        status = await server.status
        if case let .running(bound) = status, bound == port { return }
        status = await server.start(port: port, source: source)
    }
}
