// CoreAudioDeviceEnumerator — turns the HAL's device tree into `[OutputDevice]`.
import CoreAudio
import Foundation
import Models
import Services

enum CoreAudioDeviceEnumerator {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Every attached device that can actually play audio.
    ///
    /// `kAudioHardwarePropertyDevices` lists inputs, outputs and aggregates alike, so
    /// the list is filtered by ``isOutputCapable(_:)``. A device whose UID cannot be
    /// read is dropped rather than shown: without a UID there is nothing stable to
    /// persist, so it could be picked but never remembered.
    static func outputDevices() throws -> [OutputDevice] {
        let ids = try CoreAudioProperty.array(
            AudioObjectID.self,
            from: systemObject,
            address: CoreAudioProperty.address(kAudioHardwarePropertyDevices),
            operation: "kAudioHardwarePropertyDevices"
        )
        return ids.compactMap { id in
            guard isOutputCapable(id), let uid = try? uid(of: id) else { return nil }
            return OutputDevice(id: OutputDeviceID(id), uid: uid, name: (try? name(of: id)) ?? uid)
        }
    }

    /// The device the system routes to, or `nil` when there is no audio hardware.
    static func systemDefaultOutputDeviceID() -> OutputDeviceID? {
        let id = try? CoreAudioProperty.value(
            AudioObjectID.self,
            from: systemObject,
            address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice),
            operation: "kAudioHardwarePropertyDefaultOutputDevice"
        )
        guard let id, id != kAudioObjectUnknown else { return nil }
        return OutputDeviceID(id)
    }

    /// Whether the device has at least one output stream.
    ///
    /// The scope here is `Output`, NOT `Global` — a global-scope stream query counts
    /// a microphone's input streams too, which is how an input-only device ends up
    /// in an output picker.
    static func isOutputCapable(_ id: AudioObjectID) -> Bool {
        CoreAudioProperty.hasData(
            id,
            address: CoreAudioProperty.address(
                kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            )
        )
    }

    static func uid(of id: AudioObjectID) throws -> String {
        try CoreAudioProperty.string(
            from: id,
            address: CoreAudioProperty.address(kAudioDevicePropertyDeviceUID),
            operation: "kAudioDevicePropertyDeviceUID"
        )
    }

    static func name(of id: AudioObjectID) throws -> String {
        try CoreAudioProperty.string(
            from: id,
            address: CoreAudioProperty.address(kAudioObjectPropertyName),
            operation: "kAudioObjectPropertyName"
        )
    }
}
