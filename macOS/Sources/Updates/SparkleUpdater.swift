// SparkleUpdater — the macOS shell's single Sparkle updater and its delegate.
//
// Sparkle is macOS-only, so none of this exists in PlayerCore or the iOS shell.
// The feed URL, the EdDSA public key that authenticates it, and the automatic
// check opt-in all live in the app's Info.plist (see `macOS/Project.swift`); the
// matching private key is created once by `scripts/setup-sparkle-key.sh` and
// never leaves the login Keychain.
//
// Ownership: `MacAMPApp` builds exactly one ``UpdaterModel`` in its `init()` and
// injects it into the environment. Everything here is `@MainActor` because
// Sparkle annotates its own API `NS_SWIFT_UI_ACTOR`.
import Foundation
import Observation
import Sparkle

// MARK: - SparkleUpdaterDelegate

/// Maps the user's ``AppSettings/updateChannel`` onto Sparkle's channel filter.
///
/// Sparkle only offers an appcast item to updaters that allow the item's
/// `<sparkle:channel>`; untagged items are always offered. So "stable" is the
/// empty set (untagged releases only) and "beta" additionally opts into the
/// `beta` channel — the same name `scripts/make-appcast.sh --channel beta` tags.
///
/// `SPUStandardUpdaterController` holds its delegate **weakly**, so ``UpdaterModel``
/// keeps the only strong reference.
@MainActor
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    #if DEBUG
        /// Overrides the Info.plist feed for local end-to-end testing (see
        /// `docs/Distribution.md`). DEBUG-only so a shipping build can never be
        /// pointed at an attacker-chosen appcast through the environment.
        static let feedOverrideEnvironmentKey = "MACAMP_SPARKLE_FEED_URL"
    #endif

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    /// Split out from the protocol method so the mapping is testable without a
    /// live `SPUUpdater`, which cannot be constructed outside a started updater.
    var allowedChannels: Set<String> {
        switch settings.updateChannel {
        case .stable: []
        case .beta: ["beta"]
        }
    }

    func allowedChannels(for _: SPUUpdater) -> Set<String> {
        allowedChannels
    }

    #if DEBUG
        func feedURLString(for _: SPUUpdater) -> String? {
            ProcessInfo.processInfo.environment[Self.feedOverrideEnvironmentKey]
        }
    #endif
}

// MARK: - UpdaterModel

/// The SwiftUI-facing façade over the app's one `SPUStandardUpdaterController`
/// (owned by `MacAMPApp`), turning Sparkle's KVO state into observable state.
@MainActor
@Observable
final class UpdaterModel {
    /// Mirrors `SPUUpdater.canCheckForUpdates` — false while a check is already
    /// in flight, which is what the Check-for-Updates controls bind their enabled
    /// state to.
    private(set) var canCheckForUpdates: Bool

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init(controller: SPUStandardUpdaterController) {
        self.controller = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        // `@Sendable` deliberately: a closure formed here would otherwise inherit
        // `@MainActor` isolation, which Swift 6 refuses to convert to KVO's
        // non-isolated handler type. Only the `Bool` crosses, then we hop back.
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.new]
        ) { @Sendable [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// An inert model for previews and tests: no updater is attached, so nothing
    /// reaches the network and no update dialog can appear.
    private init() {
        controller = nil
        canCheckForUpdates = true
    }

    static var preview: UpdaterModel {
        UpdaterModel()
    }

    /// Runs a user-initiated check, which reports its result verbosely (including
    /// "you're up to date" and network failures) — unlike the silent scheduled one.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
