// KaraokeNotificationCenter — a shell-local wrapper over `UNUserNotificationCenter`
// that posts a system notification when a track's karaoke (vocal-removed) version
// finishes rendering, so the user hears about it even when MacAMP is in the
// background or another app is frontmost.
//
// Permission is requested LAZILY on first delivery (never at launch), and every
// path degrades gracefully: if the user denies notifications — or the process has
// no app bundle (SwiftUI previews / unit tests) — delivery is a silent no-op and
// the in-app completion toast remains the sole feedback.
import Foundation
import UserNotifications

/// Posts "karaoke version ready" system notifications, lazily requesting permission
/// on first use and degrading to a no-op when denied or unavailable.
@MainActor
final class KaraokeNotificationCenter {
    /// The system notification center, resolved lazily so SwiftUI previews and
    /// non-bundle processes never touch the User Notifications framework. `nil` ⇒ the
    /// process has no app bundle, so every delivery is a graceful no-op.
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }()

    init() {}

    /// Delivers a "karaoke version ready" notification for a completed render.
    ///
    /// Lazily requests authorization on first use (`.alert` + `.sound`). A no-op when
    /// the user has denied notifications, or the process has no bundle — the caller's
    /// in-app toast is always shown regardless, so denial degrades gracefully.
    ///
    /// - Parameter trackTitle: the finished track's title, used as the notification
    ///   body; `nil` (or empty) falls back to a generic body.
    func notifyRenderReady(trackTitle: String?) {
        guard let center else { return }
        Task { @MainActor in
            guard await Self.isAuthorized(center) else { return }
            await Self.deliverReadyNotification(on: center, trackTitle: trackTitle)
        }
    }

    /// Whether the app may post notifications, requesting permission exactly once when
    /// the user hasn't decided yet. Live settings are re-read each call so a later
    /// grant or revoke in System Settings is honored without relaunching.
    private static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            return await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Builds and schedules the immediate (`trigger: nil`) completion notification.
    private static func deliverReadyNotification(
        on center: UNUserNotificationCenter,
        trackTitle: String?
    ) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: KaraokeNotificationStrings.readyTitle)
        if let trackTitle, !trackTitle.isEmpty {
            content.body = trackTitle
        } else {
            content.body = String(localized: KaraokeNotificationStrings.readyBodyGeneric)
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

// MARK: - Localized copy (shell-local)

/// Localized copy for the karaoke render-completion system notification.
enum KaraokeNotificationStrings {
    static let readyTitle = LocalizedStringResource(
        "app.karaoke.notification.readyTitle",
        defaultValue: "Karaoke version ready",
        comment: "System notification title shown when a track's karaoke (vocal-removed) version finishes rendering"
    )
    static let readyBodyGeneric = LocalizedStringResource(
        "app.karaoke.notification.readyBody",
        defaultValue: "Your karaoke version is ready to play.",
        comment: "Generic system notification body shown when a karaoke version finishes rendering and the track title isn't available"
    )
}
