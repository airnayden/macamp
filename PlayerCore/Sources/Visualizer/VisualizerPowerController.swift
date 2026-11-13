import Foundation

// MARK: - VisualizerPowerDelegate

/// Receives render-loop activation transitions from a
/// ``VisualizerPowerController``.
///
/// The host wires `didActivate`/`didDeactivate` to start/stop the backend's
/// draw loop, guaranteeing the GPU is idle whenever the visualizer is hidden,
/// backgrounded, or running in a menu-bar-only configuration.
public protocol VisualizerPowerDelegate: AnyObject {
    /// The visualizer should begin rendering.
    func powerControllerDidActivate(_ controller: VisualizerPowerController)
    /// The visualizer should stop rendering and release per-frame state.
    func powerControllerDidDeactivate(_ controller: VisualizerPowerController)
}

// MARK: - VisualizerPowerController

/// Decides whether the visualizer should render and at what frame rate, based on
/// visibility, app-activation state, a menu-bar-only flag, and reduce-motion.
///
/// This type is intentionally NOT `@MainActor`: it is owned and mutated by the
/// `MTKViewDelegate` host, and keeping it isolation-free avoids friction at the
/// delegate boundary. All mutation happens on the owning (main) thread.
///
/// Power contract: the visualizer NEVER renders while hidden or backgrounded.
/// Every input change re-evaluates ``shouldRender`` and fires the delegate only
/// on a true transition (no redundant start/stop churn).
public final class VisualizerPowerController {
    /// `true` when the visualizer view is on-screen.
    public var isVisible = false {
        didSet { recompute() }
    }

    /// `true` when the host application is active (foreground).
    public var appActive = true {
        didSet { recompute() }
    }

    /// `true` when the app is in a menu-bar-only mode where the full visualizer
    /// surface is not shown. Suppresses rendering even if nominally "visible".
    public var menuBarOnly = false {
        didSet { recompute() }
    }

    /// `true` when the system/user requested reduced motion. Halves the target
    /// frame rate; particle/art motion is additionally damped CPU-side.
    public var reduceMotion = false {
        didSet { recompute() }
    }

    /// Receives activation transitions. Weak to avoid a host retain cycle.
    public weak var delegate: VisualizerPowerDelegate?

    private var isActive = false

    public init() {}

    /// `true` only when visible, app-active, and not menu-bar-only. The single
    /// source of truth for "is the GPU allowed to run".
    public var shouldRender: Bool {
        isVisible && appActive && !menuBarOnly
    }

    /// Target frames-per-second: `30` under reduce-motion, otherwise `60`.
    public var targetFrameRate: Int {
        reduceMotion ? 30 : 60
    }

    private func recompute() {
        let next = shouldRender
        guard next != isActive else { return }
        isActive = next
        if next {
            delegate?.powerControllerDidActivate(self)
        } else {
            delegate?.powerControllerDidDeactivate(self)
        }
    }
}
