//
//  RemoteCommandHandler.swift
//  Services
//
//  Bridges `MPRemoteCommandCenter` (Control Center, lock screen, AirPods,
//  media keys) to the ``PlaybackCoordinating`` transport. Every command goes
//  THROUGH the coordinator — never directly to the engine — so remote control
//  and the in-app UI share one source of truth.
//

import Foundation
import MediaPlayer

/// The outcome of a remote command, mapped to `MPRemoteCommandHandlerStatus`.
///
/// Modelled as a plain enum so tests can assert command results without touching
/// the real `MPRemoteCommandCenter`.
public enum RemoteCommandResult: Sendable, Equatable {
    /// The command was handled.
    case success
    /// There was nothing to act on (e.g. an empty queue).
    case noSuchContent
    /// The command could not be handled.
    case commandFailed
}

/// Registers remote-command handlers and routes them to the coordinator.
///
/// Construction is side-effect-free; call ``activate()`` to register with the
/// shared command center and ``deactivate()`` to tear the registrations down.
/// The per-command `handle…` methods are the testable seam: a test invokes them
/// directly against a spy coordinator, exactly as the registered closures do.
@MainActor
public final class RemoteCommandHandler {
    private let coordinator: any PlaybackCoordinating
    private let commandCenter: MPRemoteCommandCenter
    private var isActive = false

    public init(
        coordinator: any PlaybackCoordinating,
        commandCenter: MPRemoteCommandCenter = .shared()
    ) {
        self.coordinator = coordinator
        self.commandCenter = commandCenter
    }

    // MARK: - Activation

    /// Registers handlers for the supported commands (idempotent).
    public func activate() {
        guard !isActive else { return }
        isActive = true
        registerCommands()
    }

    /// Removes the registered handlers (idempotent).
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        for command in handledCommands {
            command.removeTarget(nil)
        }
    }

    // MARK: - Command handling (testable seam)

    @discardableResult
    public func handlePlay() -> RemoteCommandResult {
        coordinator.play()
        return .success
    }

    @discardableResult
    public func handlePause() -> RemoteCommandResult {
        coordinator.pause()
        return .success
    }

    @discardableResult
    public func handleTogglePlayPause() -> RemoteCommandResult {
        coordinator.togglePlayPause()
        return .success
    }

    @discardableResult
    public func handleNextTrack() -> RemoteCommandResult {
        coordinator.next()
        return .success
    }

    @discardableResult
    public func handlePreviousTrack() -> RemoteCommandResult {
        coordinator.previous()
        return .success
    }

    @discardableResult
    public func handleSeek(to position: TimeInterval) -> RemoteCommandResult {
        guard position.isFinite, position >= 0 else { return .commandFailed }
        coordinator.seek(to: position)
        return .success
    }

    // MARK: - Registration

    private var handledCommands: [MPRemoteCommand] {
        [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.changePlaybackPositionCommand,
        ]
    }

    private func registerCommands() {
        addHandler(to: commandCenter.playCommand) { [weak self] in
            self?.handlePlay() ?? .commandFailed
        }
        addHandler(to: commandCenter.pauseCommand) { [weak self] in
            self?.handlePause() ?? .commandFailed
        }
        addHandler(to: commandCenter.togglePlayPauseCommand) { [weak self] in
            self?.handleTogglePlayPause() ?? .commandFailed
        }
        addHandler(to: commandCenter.nextTrackCommand) { [weak self] in
            self?.handleNextTrack() ?? .commandFailed
        }
        addHandler(to: commandCenter.previousTrackCommand) { [weak self] in
            self?.handlePreviousTrack() ?? .commandFailed
        }
        registerSeekCommand()
    }

    private func addHandler(
        to command: MPRemoteCommand,
        _ handler: @escaping @MainActor () -> RemoteCommandResult
    ) {
        command.isEnabled = true
        command.addTarget { _ in
            MainActor.assumeIsolated { handler().status }
        }
    }

    private func registerSeekCommand() {
        let command = commandCenter.changePlaybackPositionCommand
        command.isEnabled = true
        command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,
                      let positionEvent = event as? MPChangePlaybackPositionCommandEvent
                else {
                    return RemoteCommandResult.commandFailed.status
                }
                return self.handleSeek(to: positionEvent.positionTime).status
            }
        }
    }
}

private extension RemoteCommandResult {
    /// Bridges to MediaPlayer's status enum at the registration boundary.
    var status: MPRemoteCommandHandlerStatus {
        switch self {
        case .success: .success
        case .noSuchContent: .noSuchContent
        case .commandFailed: .commandFailed
        }
    }
}
