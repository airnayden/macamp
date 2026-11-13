// KaraokePrewarmNotice — a non-fatal advisory the karaoke pre-warm service surfaces.
//
// The pre-warm service (todo 13, `KaraokePrewarmService`) runs best-effort background
// separation; most per-track failures are simply skipped, but a few conditions deserve
// a single user-facing, non-fatal notice (e.g. the disk filled up, so pre-warming
// stopped). This is deliberately NOT a thrown `SeparationError` — it is an advisory the
// service hands to its `onNotice` callback exactly once per stop event, so the shell can
// show a banner without treating it as a hard error. The user-facing text is a
// `LocalizedStringResource`, never a raw `String` (PlayerCore localization rule); this
// file imports only Foundation and MUST NOT import AppKit/UIKit (portability invariant).
import Foundation

/// A non-fatal advisory surfaced by ``KaraokePrewarming`` conformers as pre-warming runs.
///
/// Value-free cases so the enum is trivially `Equatable` (tests assert
/// `#expect(notices == [.diskFull])`); the user-facing copy is the case's computed
/// ``message``, resolved through the String Catalog.
public enum KaraokePrewarmNotice: Sendable, Equatable, Hashable, CaseIterable {
    /// Background pre-warming stopped because the device ran out of disk space.
    case diskFull

    /// The user-facing explanation, resolved through the String Catalog.
    public var message: LocalizedStringResource {
        switch self {
        case .diskFull:
            SeparationStrings.prewarmDiskFullNotice
        }
    }
}
