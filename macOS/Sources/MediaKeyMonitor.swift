import AppKit
import CoreGraphics

@MainActor
final class MediaKeyMonitor {
    static let shared = MediaKeyMonitor()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
            | 1 << CGEventType.keyUp.rawValue
            | (1 << 14)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyCallback,
            userInfo: nil
        ) else {
            NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                if self?.handleLocalMediaKey(event) == true { return nil }
                return event
            }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleLocalMediaKey(_ event: NSEvent) -> Bool {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return false }
        let keyCode = Int((event.data1 & 0xFFFF_0000) >> 16)
        let isKeyDown = ((event.data1 & 0x0000_FF00) >> 8) & 0x01 == 0

        guard isKeyDown, (16 ... 20).contains(keyCode) else { return false }

        NotificationCenter.default.post(
            name: .mediaKeyPressed,
            object: nil,
            userInfo: ["keyCode": keyCode]
        )
        return true
    }
}

private func mediaKeyCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard type.rawValue == 14 else { return Unmanaged.passRetained(event) }
    let nsEvent = NSEvent(cgEvent: event)
    guard let nsEvent, nsEvent.subtype.rawValue == 8 else { return Unmanaged.passRetained(event) }

    let keyCode = Int((nsEvent.data1 & 0xFFFF_0000) >> 16)
    let isKeyDown = ((nsEvent.data1 & 0x0000_FF00) >> 8) & 0x01 == 0

    guard isKeyDown, (16 ... 20).contains(keyCode) else { return Unmanaged.passRetained(event) }

    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .mediaKeyPressed,
            object: nil,
            userInfo: ["keyCode": keyCode]
        )
    }

    return nil
}

extension Notification.Name {
    static let mediaKeyPressed = Notification.Name("MacAMP.mediaKeyPressed")
}
