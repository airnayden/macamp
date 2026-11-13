// FakeOutputDeviceController — a hardware-free ``OutputDeviceControlling`` double.
//
// Scripts a device tree, its advertised rates, and — the part that matters — HOW a
// device answers a rate change: immediately, late, or never. The bounded wait itself
// is the shared `OutputDeviceRateChange.boundedWaitSeconds`, so the timeout this
// double produces is the SAME timeout the CoreAudio implementation produces. That is
// what lets the failure path be asserted by a portable test on a machine with no
// audio hardware, and on iOS, where the HAL does not exist at all.
//
// An `actor`, exactly like the production conformer, so its async surface behaves
// identically — including the fact that a caller is suspended rather than blocked.
import Foundation
import Models
import Services

/// One recorded rate-change request. A struct, not a tuple, so it stays readable.
public struct OutputRateChangeRequest: Sendable, Equatable, Hashable {
    public let rate: Double
    public let deviceID: OutputDeviceID

    public init(rate: Double, deviceID: OutputDeviceID) {
        self.rate = rate
        self.deviceID = deviceID
    }
}

/// A scripted ``OutputDeviceControlling`` for hermetic tests and previews.
public actor FakeOutputDeviceController: OutputDeviceControlling {
    /// How a scripted device answers ``setNominalRate(_:on:)``.
    public enum RateChangeBehavior: Sendable, Equatable {
        /// The device adopts the rate with no observable delay.
        case confirmsImmediately

        /// The device adopts the rate after `afterSeconds`.
        ///
        /// A value ABOVE ``OutputDeviceRateChange/boundedWaitSeconds`` models the
        /// nastiest real shape: the caller times out, and the device confirms anyway
        /// a moment later. The rate is still applied and the change handler still
        /// fires — which is exactly the late-completion the sample-rate coordinator
        /// must absorb without a duplicate reconfigure or a stale state write.
        case confirms(afterSeconds: Double)

        /// The device never answers. The caller times out and the rate never changes.
        case neverConfirms

        /// The set fails outright, before any wait.
        case fails(OutputDeviceError)
    }

    private var devices: [OutputDevice]
    private var systemDefaultID: OutputDeviceID?
    private var selectedUID: String?
    private var rates: [OutputDeviceID: [Double]]
    private var currentRates: [OutputDeviceID: Double]
    private var behavior: RateChangeBehavior
    private var onChange: (@MainActor @Sendable (OutputDeviceSnapshot) -> Void)?
    private let boundedWaitSeconds: Double

    /// Every rate change requested of this double, in call order — including the ones
    /// that timed out or were refused, so a call-order spy sees what was ASKED for
    /// independently of what happened.
    public private(set) var rateChangeRequests: [OutputRateChangeRequest] = []
    public private(set) var startCount = 0
    public private(set) var stopCount = 0

    /// - Parameters:
    ///   - devices: The attached output devices.
    ///   - systemDefaultID: The system default, defaulting to the first device.
    ///   - rates: Advertised nominal rates per device. Devices absent from the map
    ///     advertise ``defaultRates``.
    ///   - currentRates: Starting nominal rate per device. Devices absent from the
    ///     map start at 44100.
    ///   - behavior: How every device answers a rate change.
    public init(
        devices: [OutputDevice] = [.builtIn],
        systemDefaultID: OutputDeviceID? = nil,
        rates: [OutputDeviceID: [Double]] = [:],
        currentRates: [OutputDeviceID: Double] = [:],
        behavior: RateChangeBehavior = .confirmsImmediately
    ) {
        self.devices = devices
        self.systemDefaultID = systemDefaultID ?? devices.first?.id
        self.rates = rates
        self.currentRates = currentRates
        self.behavior = behavior
        boundedWaitSeconds = OutputDeviceRateChange.boundedWaitSeconds
    }

    /// The rates a device advertises when the script names none.
    public static let defaultRates: [Double] = [44100, 48000, 88200, 96000, 176_400, 192_000]

    // MARK: - OutputDeviceControlling

    public func snapshot() -> OutputDeviceSnapshot {
        OutputDeviceSnapshot(
            devices: devices,
            systemDefaultID: systemDefaultID,
            selectedUID: selectedUID
        )
    }

    public func selectDevice(uid: String?) {
        selectedUID = uid
        publish()
    }

    public func availableRates(for deviceID: OutputDeviceID) throws -> [Double] {
        try requireDevice(deviceID)
        return (rates[deviceID] ?? Self.defaultRates).sorted()
    }

    public func currentNominalRate(for deviceID: OutputDeviceID) throws -> Double {
        try requireDevice(deviceID)
        return currentRates[deviceID] ?? 44100
    }

    public func setNominalRate(_ rate: Double, on deviceID: OutputDeviceID) async throws {
        rateChangeRequests.append(OutputRateChangeRequest(rate: rate, deviceID: deviceID))
        try requireDevice(deviceID)
        let available = try availableRates(for: deviceID)
        guard available.contains(where: { OutputDeviceRateChange.matches($0, rate) }) else {
            throw OutputDeviceError.rateUnsupported(rate: rate, deviceID: deviceID, available: available)
        }
        guard try !OutputDeviceRateChange.matches(currentNominalRate(for: deviceID), rate) else { return }
        try await apply(rate, on: deviceID)
    }

    public func setOnChange(_ handler: (@MainActor @Sendable (OutputDeviceSnapshot) -> Void)?) {
        onChange = handler
    }

    public func start() {
        startCount += 1
        publish()
    }

    public func stop() {
        stopCount += 1
    }

    // MARK: - Script controls

    /// Replaces how every device answers a rate change.
    public func setBehavior(_ behavior: RateChangeBehavior) {
        self.behavior = behavior
    }

    /// Replaces the attached device list and republishes.
    ///
    /// Models a plug or an unplug: pass a list without the currently-selected device
    /// to exercise the fall-back-to-default path.
    public func simulateDeviceList(_ devices: [OutputDevice], systemDefaultID: OutputDeviceID? = nil) {
        self.devices = devices
        self.systemDefaultID = systemDefaultID ?? devices.first?.id
        publish()
    }

    /// Changes only the system default and republishes.
    public func simulateSystemDefault(_ deviceID: OutputDeviceID?) {
        systemDefaultID = deviceID
        publish()
    }

    // MARK: - Internals

    private func apply(_ rate: Double, on deviceID: OutputDeviceID) async throws {
        switch behavior {
        case .confirmsImmediately:
            currentRates[deviceID] = rate
        case let .confirms(afterSeconds) where afterSeconds <= boundedWaitSeconds:
            try await Task.sleep(for: .seconds(afterSeconds))
            currentRates[deviceID] = rate
        case let .confirms(afterSeconds):
            scheduleLateConfirmation(of: rate, on: deviceID, afterSeconds: afterSeconds)
            try await Task.sleep(for: .seconds(boundedWaitSeconds))
            throw timedOut(rate, deviceID)
        case .neverConfirms:
            try await Task.sleep(for: .seconds(boundedWaitSeconds))
            throw timedOut(rate, deviceID)
        case let .fails(error):
            throw error
        }
    }

    /// Applies a rate AFTER the caller has already given up on it.
    ///
    /// Detached on purpose: the caller's task is about to throw, so a child task
    /// would be cancelled along with it and the late confirmation — the whole point
    /// of this branch — would never arrive.
    private func scheduleLateConfirmation(of rate: Double, on deviceID: OutputDeviceID, afterSeconds: Double) {
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(afterSeconds))
            await self?.confirmLate(rate, on: deviceID)
        }
    }

    private func confirmLate(_ rate: Double, on deviceID: OutputDeviceID) {
        guard devices.contains(where: { $0.id == deviceID }) else { return }
        currentRates[deviceID] = rate
        publish()
    }

    private func timedOut(_ rate: Double, _ deviceID: OutputDeviceID) -> OutputDeviceError {
        .rateChangeTimedOut(rate: rate, deviceID: deviceID, afterSeconds: boundedWaitSeconds)
    }

    private func requireDevice(_ deviceID: OutputDeviceID) throws {
        guard devices.contains(where: { $0.id == deviceID }) else {
            throw OutputDeviceError.deviceNotFound(deviceID)
        }
    }

    private func publish() {
        guard let onChange else { return }
        let current = snapshot()
        Task { @MainActor in onChange(current) }
    }
}

public extension OutputDevice {
    /// A stand-in for the machine's built-in output.
    static let builtIn = OutputDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")

    /// A stand-in for an attached USB interface — the second device every picker,
    /// fallback and rate-switch test needs.
    static let usbDAC = OutputDevice(id: 2, uid: "USB-DAC-0001", name: "USB Audio DAC")
}
