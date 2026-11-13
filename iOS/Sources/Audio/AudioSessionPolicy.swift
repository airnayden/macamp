// AudioSessionPolicy — the pure decision core for iOS audio-session handling.
//
// This is a platform-neutral, side-effect-free state machine: given a system
// audio event (an interruption, a route change, an engine-configuration change,
// or an app-lifecycle transition) plus whether the engine is currently
// rendering, it returns the single transport action the ``AudioSessionController``
// should carry out. It imports ONLY Foundation — no AVFAudio — so the rules are
// trivially reviewable and exercised by ``runDebugSelfCheck()`` without a live
// audio session, MediaPlayer, or a hardware route.
//
// The invariants encoded here come straight from the iOS Human Interface
// Guidelines and the AVAudioSession contract:
//
//   * An interruption begins  → pause (the system has already ducked us).
//   * An interruption ends     → resume ONLY if the system grants `.shouldResume`
//                                AND we were playing when it began.
//   * A headphone / Bluetooth device disconnects (`oldDeviceUnavailable`)
//                              → pause; NEVER keep blasting the speaker.
//   * Any other route change   → do nothing (never auto-switch or auto-resume).
//   * The engine configuration changes → restart the graph, but ONLY while not
//                                suspended (so a config change *during* an
//                                interruption never resumes mid-interruption).
//   * App background / foreground → no-op; `UIBackgroundModes: [audio]` keeps the
//                                engine rendering, so there is nothing to do.
//
// Because PlayerCore stays platform-agnostic, this policy and the controller that
// drives it live in the iOS app target, not in PlayerCore.
import Foundation

/// A system event the audio session reacts to, expressed platform-neutrally so
/// the policy never needs AVFAudio to be reviewed or self-checked.
enum AudioSessionEvent: Equatable {
    /// The system began an interruption (a call, Siri, another app): audio is
    /// already ducked/stopped by the OS.
    case interruptionBegan
    /// The interruption ended. `shouldResume` mirrors the system's
    /// `AVAudioSession.InterruptionOptions.shouldResume` hint.
    case interruptionEnded(shouldResume: Bool)
    /// The audio route changed (device (un)plugged, override, category change).
    case routeChanged(reason: AudioSessionRouteChangeReason)
    /// The audio engine's configuration changed (sample-rate / channel / route
    /// reconfiguration) — the authoritative signal to restart the graph.
    case configurationChanged
    /// The app moved to the background.
    case appBackgrounded
    /// The app returned to the foreground.
    case appForegrounded
}

/// A platform-neutral mirror of the subset of `AVAudioSession.RouteChangeReason`
/// the policy distinguishes; everything the policy treats identically collapses
/// into ``other``.
enum AudioSessionRouteChangeReason: Equatable {
    /// The previous output device became unavailable (headphones unplugged, a
    /// Bluetooth device disconnected). iOS convention: pause.
    case oldDeviceUnavailable
    /// A new output device became available (headphones plugged in, Bluetooth
    /// connected). We never auto-switch playback onto it.
    case newDeviceAvailable
    /// The route changed because of an explicit category/port override.
    case override
    /// The session category changed.
    case categoryChange
    /// The device woke from sleep.
    case wakeFromSleep
    /// Any other reason the policy treats as a no-op.
    case other
}

/// The single transport action the controller performs in response to an event.
enum AudioSessionAction: Equatable {
    /// Do nothing.
    case none
    /// Suspend rendering, retaining position.
    case pause
    /// Resume rendering.
    case resume
    /// Re-activate the session and restart the engine graph (replaying only if
    /// playback was active).
    case restart
}

/// The pure audio-session decision state machine.
///
/// Holds the minimal memory needed to make correct resume/restart decisions —
/// whether an interruption is in effect, whether the session is suspended, and
/// whether playback was active when the current interruption began — and exposes
/// one ``reduce(_:isPlaying:)`` transition. It is a value type with no reference
/// to the engine, the session, or any I/O.
struct AudioSessionPolicy: Equatable {
    /// `true` between an `interruptionBegan` and its matching `interruptionEnded`.
    private(set) var isInterrupted = false
    /// `true` while the session/engine is suspended (currently: for the duration
    /// of an interruption). Guards the configuration-change restart so a config
    /// change mid-interruption never resumes playback.
    private(set) var isSuspended = false
    /// Whether the engine was rendering when the current interruption began, so
    /// an `interruptionEnded(shouldResume:)` can decide whether to resume.
    private(set) var wasPlayingBeforeInterruption = false

    /// Maps an `event` (and whether the engine is rendering right now) to the
    /// single action the controller must perform, mutating the retained flags.
    ///
    /// - Parameters:
    ///   - event: The system event being handled.
    ///   - isPlaying: Whether the engine is currently rendering audio.
    /// - Returns: The action the controller carries out on the transport.
    mutating func reduce(_ event: AudioSessionEvent, isPlaying: Bool) -> AudioSessionAction {
        switch event {
        case .interruptionBegan:
            wasPlayingBeforeInterruption = isPlaying
            isInterrupted = true
            isSuspended = true
            return .pause

        case let .interruptionEnded(shouldResume):
            let resume = shouldResume && wasPlayingBeforeInterruption && isInterrupted
            isInterrupted = false
            isSuspended = false
            wasPlayingBeforeInterruption = false
            return resume ? .resume : .none

        case let .routeChanged(reason):
            return reason == .oldDeviceUnavailable ? .pause : .none

        case .configurationChanged:
            return isSuspended ? .none : .restart

        case .appBackgrounded, .appForegrounded:
            return .none
        }
    }
}

#if DEBUG
    extension AudioSessionPolicy {
        /// A tiny, dependency-free verification harness for the policy, run once at
        /// launch in DEBUG (from ``AudioSessionController/activate()``). It asserts
        /// every documented transition so a regression in the rules trips immediately
        /// in development — the policy is pure, so this stands in for a unit-test
        /// target the frozen `iOS/Project.swift` manifest cannot add.
        static func runDebugSelfCheck() {
            checkInterruptionResumes()
            checkInterruptionStaysPaused()
            checkRouteChanges()
            checkConfigurationChanges()
            checkLifecycleIsNoOp()
        }

        /// began (while playing) → pause; a config change *during* the interruption is
        /// suppressed; ended + shouldResume → resume.
        private static func checkInterruptionResumes() {
            var interrupted = AudioSessionPolicy()
            assert(interrupted.reduce(.interruptionBegan, isPlaying: true) == .pause)
            assert(interrupted.isInterrupted && interrupted.isSuspended)
            // No resume during an active interruption: a config change is a no-op.
            assert(interrupted.reduce(.configurationChanged, isPlaying: false) == .none)
            assert(interrupted.reduce(.interruptionEnded(shouldResume: true), isPlaying: false) == .resume)
            assert(!interrupted.isInterrupted && !interrupted.isSuspended)
        }

        /// ended without `.shouldResume` stays paused; began-while-idle never resumes.
        private static func checkInterruptionStaysPaused() {
            var noResume = AudioSessionPolicy()
            _ = noResume.reduce(.interruptionBegan, isPlaying: true)
            assert(noResume.reduce(.interruptionEnded(shouldResume: false), isPlaying: false) == .none)

            var idleInterrupt = AudioSessionPolicy()
            assert(idleInterrupt.reduce(.interruptionBegan, isPlaying: false) == .pause)
            // Was not playing, so even a resume hint leaves it paused.
            assert(idleInterrupt.reduce(.interruptionEnded(shouldResume: true), isPlaying: false) == .none)
        }

        /// A lost device pauses; a new device (or any other reason) is a no-op.
        private static func checkRouteChanges() {
            var route = AudioSessionPolicy()
            assert(route.reduce(.routeChanged(reason: .oldDeviceUnavailable), isPlaying: true) == .pause)
            assert(route.reduce(.routeChanged(reason: .newDeviceAvailable), isPlaying: false) == .none)
            assert(route.reduce(.routeChanged(reason: .other), isPlaying: true) == .none)
        }

        /// A config change while not suspended restarts; while suspended it is a no-op.
        private static func checkConfigurationChanges() {
            var config = AudioSessionPolicy()
            assert(config.reduce(.configurationChanged, isPlaying: true) == .restart)

            var suspended = AudioSessionPolicy()
            _ = suspended.reduce(.interruptionBegan, isPlaying: true)
            assert(suspended.reduce(.configurationChanged, isPlaying: false) == .none)
        }

        /// Background / foreground transitions never touch the transport (background
        /// audio keeps the engine rendering).
        private static func checkLifecycleIsNoOp() {
            var lifecycle = AudioSessionPolicy()
            assert(lifecycle.reduce(.appBackgrounded, isPlaying: true) == .none)
            assert(lifecycle.reduce(.appForegrounded, isPlaying: true) == .none)
        }
    }
#endif
