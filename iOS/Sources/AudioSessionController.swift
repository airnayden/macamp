// AudioSessionController — configures + activates the app's AVAudioSession and
// drives the transport through system audio events.
//
// This is the iOS-only audio-session layer (Task 34). PlayerCore stays
// platform-agnostic — it has no `AVAudioSession` — so the session lives here in
// the app target and bridges to the engine through PlayerCore's
// ``PlaybackCoordinating`` protocol. The controller is a thin, imperative shell:
// every decision is delegated to the pure ``AudioSessionPolicy`` state machine,
// which is exhaustively self-checked at launch in DEBUG.
//
// Responsibilities:
//   * Configure the session for music playback (`.playback` category) and
//     activate it so audio keeps rendering when the app is backgrounded
//     (`UIBackgroundModes: [audio]`, already declared in `iOS/Project.swift`).
//   * Observe interruptions (calls, Siri, other apps): pause on `.began`, resume
//     on `.ended` only when the system grants `.shouldResume`.
//   * Observe route changes: pause when the output device disappears
//     (`oldDeviceUnavailable` — headphones unplugged, Bluetooth disconnected),
//     per the iOS HIG; never keep playing on the speaker.
//   * Observe `AVAudioEngineConfigurationChange`: restart the graph, guarded by
//     the policy's `isSuspended` flag so a config change mid-interruption never
//     resumes playback.
//   * Keep the now-playing presentation (Control Center / lock screen) in sync
//     across those transitions.
//
// Notifications are delivered on `.main` (`OperationQueue.main`) so the handlers
// run on the main actor; the audio engine posts its configuration-change
// notification on an internal queue, which is exactly why the explicit main-queue
// hop + `MainActor.assumeIsolated` bridge is required. There is NO AppKit here.
import AudioEngine
import AVFAudio
import Foundation
import os
import Services

/// The seam the app wires to bring the audio session up (and tear it down).
@MainActor
protocol AudioSessionControlling: AnyObject {
    /// Configures + activates the playback session and starts observing system
    /// audio events. Idempotent: a second call while already active is a no-op.
    func activate()
    /// Stops observing and deactivates the session.
    func deactivate()
}

/// Owns the `AVAudioSession` lifecycle for iOS playback and routes system audio
/// events through ``AudioSessionPolicy`` into the ``PlaybackCoordinating``
/// transport and the ``NowPlayingControlling`` presentation.
@MainActor
final class AudioSessionController: AudioSessionControlling {
    private let session = AVAudioSession.sharedInstance()
    private let coordinator: any PlaybackCoordinating
    private let nowPlaying: (any NowPlayingControlling)?
    private let logger = Logger(subsystem: "si.macamp.MacAMP.ios", category: "audio-session")

    /// The pure decision core. Mutated only on the main actor.
    private var policy = AudioSessionPolicy()
    /// Block-observer tokens, retained so ``deactivate()`` can remove them.
    private var observers: [any NSObjectProtocol] = []

    /// Creates a controller bound to the playback transport.
    ///
    /// Construction is side-effect-free — the real `AVAudioSession` is untouched
    /// until ``activate()`` — so the composition root can build it eagerly while
    /// previews simply never activate it.
    ///
    /// - Parameters:
    ///   - coordinator: The transport the session drives (PlayerCore's seam).
    ///   - nowPlaying: The now-playing presentation kept in sync on pause/resume.
    init(
        coordinator: any PlaybackCoordinating,
        nowPlaying: (any NowPlayingControlling)? = nil
    ) {
        self.coordinator = coordinator
        self.nowPlaying = nowPlaying
    }

    func activate() {
        guard observers.isEmpty else { return }
        #if DEBUG
            AudioSessionPolicy.runDebugSelfCheck()
        #endif
        configureCategory()
        observeInterruptions()
        observeRouteChanges()
        observeConfigurationChanges()
        activateSession()
    }

    func deactivate() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.error("session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Session configuration

private extension AudioSessionController {
    /// Sets the `.playback` category so audio is non-mixable, honours the silent
    /// switch correctly for media, and continues in the background.
    func configureCategory() {
        do {
            try session.setCategory(.playback, mode: .default)
        } catch {
            logger.error("session category failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Activates the session before any rendering begins. Failures are logged and
    /// swallowed — a transient activation failure must never crash the app.
    func activateSession() {
        do {
            try session.setActive(true)
        } catch {
            logger.error("session activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Observation

private extension AudioSessionController {
    func observeInterruptions() {
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let event = Self.interruptionEvent(from: notification) else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observers.append(token)
    }

    func observeRouteChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let event = Self.routeChangeEvent(from: notification) else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observers.append(token)
    }

    func observeConfigurationChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.configurationChanged) }
        }
        observers.append(token)
    }
}

// MARK: - Event handling

private extension AudioSessionController {
    /// Feeds an event (plus the live transport state) through the policy and
    /// performs the single action it returns.
    func handle(_ event: AudioSessionEvent) {
        let isPlaying = coordinator.state.playback == .playing
        apply(policy.reduce(event, isPlaying: isPlaying))
    }

    func apply(_ action: AudioSessionAction) {
        switch action {
        case .none:
            break
        case .pause:
            coordinator.pause()
            nowPlaying?.updatePlayback(.paused(elapsed: coordinator.currentTime))
            logger.notice("paused for audio-session event")
        case .resume:
            coordinator.play()
            nowPlaying?.updatePlayback(.playing(elapsed: coordinator.currentTime))
            logger.notice("resumed after interruption ended")
        case .restart:
            restartGraph()
        }
    }

    /// Re-activates the session after a configuration change and replays only if
    /// playback was active — so a config change that follows a deliberate pause
    /// (e.g. a headphone unplug) never blasts the speaker. Main-queue delivery
    /// guarantees the preceding pause is already applied here.
    func restartGraph() {
        let wasPlaying = coordinator.state.playback == .playing
        activateSession()
        guard wasPlaying else {
            logger.notice("configuration changed while idle; session re-activated")
            return
        }
        coordinator.play()
        nowPlaying?.updatePlayback(.playing(elapsed: coordinator.currentTime))
        logger.notice("configuration changed; restarted playback")
    }
}

// MARK: - Notification parsing (pure, off-actor safe)

private extension AudioSessionController {
    /// Translates an interruption notification into a policy event. `nonisolated`
    /// + `static` so it can run synchronously inside the `@Sendable` observer
    /// block before the main-actor hop.
    nonisolated static func interruptionEvent(from notification: Notification) -> AudioSessionEvent? {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    nonisolated static func routeChangeEvent(from notification: Notification) -> AudioSessionEvent? {
        guard let info = notification.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return nil }
        return .routeChanged(reason: mapRouteReason(reason))
    }

    /// Collapses the platform route-change reason onto the policy's neutral enum.
    nonisolated static func mapRouteReason(
        _ reason: AVAudioSession.RouteChangeReason
    ) -> AudioSessionRouteChangeReason {
        switch reason {
        case .oldDeviceUnavailable: .oldDeviceUnavailable
        case .newDeviceAvailable: .newDeviceAvailable
        case .override: .override
        case .categoryChange: .categoryChange
        case .wakeFromSleep: .wakeFromSleep
        default: .other
        }
    }
}
