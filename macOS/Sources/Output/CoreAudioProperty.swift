// CoreAudioProperty — the two-call idiom, once, behind typed accessors.
//
// Every HAL read is the same shape: ask `AudioObjectGetPropertyDataSize` how many
// bytes the property occupies, allocate exactly that, then ask
// `AudioObjectGetPropertyData` to fill it. Open-coding that per property is how
// buffer-size bugs and leaked CFStrings get in, so it is written once here and the
// rest of `Sources/Output/` only ever names a selector.
//
// This file — and this directory — is the ONLY place in MacAMP that may import
// CoreAudio. `PlayerCore` speaks to it exclusively through `OutputDeviceControlling`,
// which is what keeps `PlayerCore-Package` building for the iOS Simulator.
import CoreAudio
import Foundation
import Services

enum CoreAudioProperty {
    /// A property address in the global scope on the main element — the shape the
    /// overwhelming majority of HAL properties use, including every one this module
    /// reads except the output-stream probe.
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Whether the object carries any data for this property.
    ///
    /// A size-only query, which is exactly how output capability is detected: a
    /// device with zero bytes of output streams cannot play audio.
    static func hasData(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        var target = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &target, 0, nil, &size)
        return status == noErr && size > 0
    }

    static func dataSize(
        _ object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> UInt32 {
        var target = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(object, &target, 0, nil, &size)
        guard status == noErr else {
            throw OutputDeviceError.platformFailure(operation: operation, status: status)
        }
        return size
    }

    /// Reads a fixed-size trivial value (`UInt32`, `Float64`, …).
    static func value<Value>(
        _: Value.Type,
        from object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> Value {
        var target = address
        var size = UInt32(MemoryLayout<Value>.size)
        var storage = [UInt8](repeating: 0, count: MemoryLayout<Value>.size)
        let status = storage.withUnsafeMutableBytes { raw -> OSStatus in
            guard let destination = raw.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(object, &target, 0, nil, &size, destination)
        }
        guard status == noErr else {
            throw OutputDeviceError.platformFailure(operation: operation, status: status)
        }
        return storage.withUnsafeBytes { $0.loadUnaligned(as: Value.self) }
    }

    /// Reads a variable-length array of trivial values.
    ///
    /// The element count comes from the size the HAL actually WROTE, not the size it
    /// quoted a moment earlier — a device list can shrink between the two calls when
    /// something is unplugged mid-enumeration, and trusting the quote would read past
    /// the live data.
    static func array<Element>(
        _: Element.Type,
        from object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> [Element] {
        var target = address
        var size = try dataSize(object, address: address, operation: operation)
        let stride = MemoryLayout<Element>.stride
        guard size > 0, stride > 0 else { return [] }
        var storage = [UInt8](repeating: 0, count: Int(size))
        let status = storage.withUnsafeMutableBytes { raw -> OSStatus in
            guard let destination = raw.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(object, &target, 0, nil, &size, destination)
        }
        guard status == noErr else {
            throw OutputDeviceError.platformFailure(operation: operation, status: status)
        }
        let count = min(Int(size), storage.count) / stride
        return storage.withUnsafeBytes { raw in
            (0 ..< count).map { raw.loadUnaligned(fromByteOffset: $0 * stride, as: Element.self) }
        }
    }

    /// Reads a `CFString`-valued property.
    ///
    /// `Unmanaged` rather than a bridged `CFString` out-parameter because the HAL
    /// returns the string at +1: letting ARC bridge it directly retains a second time
    /// and leaks the string on every enumeration.
    static func string(
        from object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> String {
        var target = address
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(object, &target, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw OutputDeviceError.platformFailure(operation: operation, status: status)
        }
        guard let unmanaged else {
            throw OutputDeviceError.platformFailure(operation: operation, status: kAudio_ParamError)
        }
        return unmanaged.takeRetainedValue() as String
    }

    static func setValue<Value>(
        _ value: Value,
        on object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        operation: String
    ) throws {
        var target = address
        var payload = value
        let size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafePointer(to: &payload) { pointer in
            AudioObjectSetPropertyData(object, &target, 0, nil, size, pointer)
        }
        guard status == noErr else {
            throw OutputDeviceError.platformFailure(operation: operation, status: status)
        }
    }
}
