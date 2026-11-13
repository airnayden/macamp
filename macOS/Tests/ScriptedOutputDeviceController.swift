// ScriptedOutputDeviceController — a hardware-free `OutputDeviceControlling` for
// shell-side suites.
//
// WHY A SECOND DOUBLE EXISTS. `PlayerCoreTestSupport` already ships
// `FakeOutputDeviceController`, and that is the one to reach for from any PlayerCore
// suite. It is unreachable from here: adding the product to `macampMacTests` makes
// Tuist infer the whole SPM product as macOS-only and `tuist generate` then
// hard-fails linting for every iOS-capable PlayerCore test target that depends on it
// (measured; a `condition: .when([.macos])` on the edge does not help). See the note
// in `macOS/Project.swift`.
//
// The drift risk that split creates is contained by reading the ONE number that
// matters — `OutputDeviceRateChange.boundedWaitSeconds` — from the shared seam rather
// than restating it, so a change to the bounded wait moves both doubles at once.
// Everything else here is scripting, not HAL modelling: the seam's own timing
// semantics stay covered by PlayerCore's `FakeOutputDeviceControllerTests`.
import Foundation
import Models
import Services

actor ScriptedOutputDeviceController: OutputDeviceControlling {
    enum Behavior: Equatable {
        case confirmsImmediately
        /// Above ``OutputDeviceRateChange/boundedWaitSeconds`` this models the nasty
        /// shape: the caller times out, then the device confirms anyway.
        case confirms(afterSeconds: Double)
        case neverConfirms
    }

    private var devices: [OutputDevice]
    private var rates: [OutputDeviceID: [Double]]
    private var currentRates: [OutputDeviceID: Double]
    private var behavior: Behavior

    /// Every rate change ASKED for, in call order — including refused and timed-out
    /// ones, so "issued no set at all" is distinguishable from "set and it failed".
    private(set) var rateChangeRequests: [OutputRateChange] = []

    struct OutputRateChange: Equatable {
        let rate: Double
        let deviceID: OutputDeviceID
    }

    init(
        devices: [OutputDevice],
        rates: [OutputDeviceID: [Double]],
        currentRates: [OutputDeviceID: Double],
        behavior: Behavior = .confirmsImmediately
    ) {
        self.devices = devices
        self.rates = rates
        self.currentRates = currentRates
        self.behavior = behavior
    }

    func snapshot() -> OutputDeviceSnapshot {
        OutputDeviceSnapshot(devices: devices, systemDefaultID: devices.first?.id)
    }

    func selectDevice(uid _: String?) {}

    func availableRates(for deviceID: OutputDeviceID) throws -> [Double] {
        try requireDevice(deviceID)
        return (rates[deviceID] ?? []).sorted()
    }

    func currentNominalRate(for deviceID: OutputDeviceID) throws -> Double {
        try requireDevice(deviceID)
        return currentRates[deviceID] ?? 44100
    }

    func setNominalRate(_ rate: Double, on deviceID: OutputDeviceID) async throws {
        rateChangeRequests.append(OutputRateChange(rate: rate, deviceID: deviceID))
        try requireDevice(deviceID)
        let available = try availableRates(for: deviceID)
        guard available.contains(where: { OutputDeviceRateChange.matches($0, rate) }) else {
            throw OutputDeviceError.rateUnsupported(rate: rate, deviceID: deviceID, available: available)
        }
        guard try !OutputDeviceRateChange.matches(currentNominalRate(for: deviceID), rate) else { return }
        try await apply(rate, on: deviceID)
    }

    func setOnChange(_: (@MainActor @Sendable (OutputDeviceSnapshot) -> Void)?) {}

    func start() {}

    func stop() {}

    private func apply(_ rate: Double, on deviceID: OutputDeviceID) async throws {
        let bound = OutputDeviceRateChange.boundedWaitSeconds
        switch behavior {
        case .confirmsImmediately:
            currentRates[deviceID] = rate
        case let .confirms(afterSeconds) where afterSeconds <= bound:
            try await Task.sleep(for: .seconds(afterSeconds))
            currentRates[deviceID] = rate
        case let .confirms(afterSeconds):
            scheduleLateConfirmation(of: rate, on: deviceID, afterSeconds: afterSeconds)
            try await Task.sleep(for: .seconds(bound))
            throw timedOut(rate, deviceID, after: bound)
        case .neverConfirms:
            try await Task.sleep(for: .seconds(bound))
            throw timedOut(rate, deviceID, after: bound)
        }
    }

    /// Detached because the caller's task is about to throw, and a child task would be
    /// cancelled with it — losing the late confirmation this branch exists to produce.
    private func scheduleLateConfirmation(of rate: Double, on deviceID: OutputDeviceID, afterSeconds: Double) {
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(afterSeconds))
            await self?.confirmLate(rate, on: deviceID)
        }
    }

    private func confirmLate(_ rate: Double, on deviceID: OutputDeviceID) {
        guard devices.contains(where: { $0.id == deviceID }) else { return }
        currentRates[deviceID] = rate
    }

    private func timedOut(_ rate: Double, _ deviceID: OutputDeviceID, after seconds: Double) -> OutputDeviceError {
        .rateChangeTimedOut(rate: rate, deviceID: deviceID, afterSeconds: seconds)
    }

    private func requireDevice(_ deviceID: OutputDeviceID) throws {
        guard devices.contains(where: { $0.id == deviceID }) else {
            throw OutputDeviceError.deviceNotFound(deviceID)
        }
    }
}

extension OutputDevice {
    /// The stand-in DAC every rate-switch case in this target routes through.
    static let scriptedDAC = OutputDevice(id: 2, uid: "USB-DAC-0001", name: "USB Audio DAC")
}
