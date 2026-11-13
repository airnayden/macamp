import Foundation
@testable import MacAMP
import Sparkle
import Testing

/// Headless coverage for the Sparkle wiring. The Preferences pane's button binds
/// `.disabled(!updater.canCheckForUpdates)` and its action to
/// `UpdaterModel.checkForUpdates()`, so asserting the model's state here is the
/// non-GUI equivalent of asserting the button is live.
@MainActor
@Suite("SparkleUpdaterTests", .serialized)
struct SparkleUpdaterTests {
    @Test("stable accepts only untagged appcast items")
    func stableChannelAllowsNoExtraChannels() {
        let settings = AppSettings.preview
        settings.updateChannel = .stable

        #expect(SparkleUpdaterDelegate(settings: settings).allowedChannels.isEmpty)
    }

    /// The name must stay identical to `scripts/make-appcast.sh --channel beta`,
    /// which is what writes `<sparkle:channel>` into the published appcast.
    @Test("beta opts into exactly the channel the appcast tags")
    func betaChannelMatchesAppcastTag() {
        let settings = AppSettings.preview
        settings.updateChannel = .beta

        #expect(SparkleUpdaterDelegate(settings: settings).allowedChannels == ["beta"])
    }

    @Test("switching the preference retargets the live delegate")
    func channelTracksTheSettingsInstance() {
        let settings = AppSettings.preview
        let delegate = SparkleUpdaterDelegate(settings: settings)

        settings.updateChannel = .beta
        #expect(delegate.allowedChannels == ["beta"])
        settings.updateChannel = .stable
        #expect(delegate.allowedChannels.isEmpty)
    }

    /// Also proves the host app is configured properly for Sparkle: `startUpdater`
    /// only flips `canCheckForUpdates` after validating the bundle's `SUFeedURL`,
    /// EdDSA public key and version keys.
    @Test("a started updater leaves the Check for Updates controls enabled")
    func startedUpdaterEnablesChecking() {
        let settings = AppSettings.preview
        let delegate = SparkleUpdaterDelegate(settings: settings)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )

        #expect(UpdaterModel(controller: controller).canCheckForUpdates)
        // Sparkle holds the delegate weakly; keep it alive for the assertion above.
        withExtendedLifetime(delegate) {}
    }

    @Test("the inert preview model never touches Sparkle")
    func previewModelIsInert() {
        let model = UpdaterModel.preview

        #expect(model.canCheckForUpdates)
        model.checkForUpdates()
    }
}
