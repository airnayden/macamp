// CoreAudioNominalRate — reading and, the hard part, SETTING a device's clock.
//
// Setting `kAudioDevicePropertyNominalSampleRate` is ASYNCHRONOUS. The call returns
// straight away and the device re-clocks some milliseconds later, announcing the new
// value through a property listener. There is no completion handler, so the only
// correct shape is: register the listener, THEN set, THEN wait with a bound.
import CoreAudio
import Foundation
import Models
import Services

enum CoreAudioNominalRate {
    /// The nominal-rate property address.
    ///
    /// The scope MUST be `Global`. `kAudioDevicePropertyNominalSampleRate` in the
    /// output scope returns `kAudioHardwareUnknownPropertyError` on most devices —
    /// the clock belongs to the device, not to one of its directions — and a listener
    /// registered on the output scope never fires, which turns every rate change into
    /// a two-second timeout that nonetheless succeeds.
    static let address = CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)

    static func current(of deviceID: AudioObjectID) throws -> Double {
        try CoreAudioProperty.value(
            Float64.self,
            from: deviceID,
            address: address,
            operation: "kAudioDevicePropertyNominalSampleRate"
        )
    }

    /// Every nominal rate the device advertises, ascending.
    ///
    /// The HAL answers in `AudioValueRange`s. A discrete rate arrives as a degenerate
    /// range (`mMinimum == mMaximum`); aggregate and virtual devices can advertise a
    /// genuine continuous span, which ``CoreAudioRateCatalog`` reduces to the standard
    /// rates inside it.
    static func available(of deviceID: AudioObjectID) throws -> [Double] {
        let ranges = try CoreAudioProperty.array(
            AudioValueRange.self,
            from: deviceID,
            address: CoreAudioProperty.address(kAudioDevicePropertyAvailableNominalSampleRates),
            operation: "kAudioDevicePropertyAvailableNominalSampleRates"
        )
        return CoreAudioRateCatalog.rates(in: ranges)
    }

    /// Retunes the device and waits up to `timeoutSeconds` for it to confirm.
    ///
    /// Never blocks: the wait is a continuation the listener resumes, so the caller's
    /// task suspends and its thread is returned to the pool.
    static func set(_ rate: Double, on deviceID: AudioObjectID, timeoutSeconds: Double) async throws {
        var target = address
        let queue = DispatchQueue(label: "com.example.macamp.output.nominal-rate")
        let waiter = RateChangeWaiter()
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            guard let observed = try? current(of: deviceID),
                  OutputDeviceRateChange.matches(observed, rate) else { return }
            waiter.finish(.success(()))
        }

        let added = AudioObjectAddPropertyListenerBlock(deviceID, &target, queue, listener)
        guard added == noErr else {
            throw OutputDeviceError.platformFailure(
                operation: "AudioObjectAddPropertyListenerBlock(NominalSampleRate)",
                status: added
            )
        }
        defer { AudioObjectRemovePropertyListenerBlock(deviceID, &target, queue, listener) }

        try CoreAudioProperty.setValue(
            Float64(rate),
            on: deviceID,
            address: address,
            operation: "kAudioDevicePropertyNominalSampleRate(set)"
        )

        let deadline = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard !Task.isCancelled else { return }
            waiter.finish(.failure(OutputDeviceError.rateChangeTimedOut(
                rate: rate,
                deviceID: OutputDeviceID(deviceID),
                afterSeconds: timeoutSeconds
            )))
        }
        defer { deadline.cancel() }

        try await waiter.wait()
    }
}

/// A one-shot rendezvous between a HAL listener block and an awaiting task.
///
/// Both ends can win: the device can confirm before the continuation is even
/// installed, and the deadline can fire while the listener is mid-flight. The lock
/// makes "first result wins, exactly one resume" true in both orders — resuming a
/// `CheckedContinuation` twice is a runtime trap, and dropping the only resume hangs
/// playback forever.
private final class RateChangeWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var settled: Result<Void, any Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let alreadySettled: Result<Void, any Error>? = lock.withLock {
                if let settled { return settled }
                self.continuation = continuation
                return nil
            }
            if let alreadySettled { continuation.resume(with: alreadySettled) }
        }
    }

    func finish(_ result: Result<Void, any Error>) {
        let waiting: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard settled == nil else { return nil }
            settled = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
