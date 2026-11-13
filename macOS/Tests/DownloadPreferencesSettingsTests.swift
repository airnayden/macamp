// DownloadPreferencesSettingsTests — `AppSettings.downloads` as a persisted value.
//
// Three claims that would each look correct in the Downloads pane while being wrong:
//
//   1. A default that is not native-passthrough m4a at best quality. A fresh install
//      must not silently opt the listener into an ffmpeg transcode, so the defaults
//      are asserted against a freshly wiped domain rather than a live app.
//   2. A preference that does not survive a relaunch. `downloads` is ONE stored
//      property over SIX flat keys, so the round trip is asserted through a second
//      `AppSettings` built on the same suite — the relaunch this shell will do.
//   3. A garbage stored value that takes the settings store down at launch, or that
//      takes its neighbours with it. Each key is seeded with a type or token it will
//      never legitimately hold, and the surviving keys are asserted alongside.
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Download preferences settings")
@MainActor
struct DownloadPreferencesSettingsTests {
    @Test("a fresh install downloads native m4a at best quality, to the default folder")
    func theDefaultStateIsNativePassthrough() {
        let settings = AppSettings(defaults: Self.store(named: "\(Self.suitePrefix).default"))

        #expect(settings.downloads.destinationPath == nil)
        #expect(settings.downloads.audioFormat == .m4a)
        #expect(settings.downloads.audioQuality == .best)
        #expect(settings.downloads.lastEngineUpdateCheck == nil)
        #expect(settings.downloads.maxConcurrent == DownloadQueueLimits.defaultConcurrentDownloads)
        #expect(settings.downloads == DownloadPreferences())
    }

    @Test("the concurrency choice round-trips through a reload")
    func theConcurrencyChoiceRoundTrips() {
        let store = Self.store(named: "\(Self.suitePrefix).concurrencyRoundTrip")
        let settings = AppSettings(defaults: store)

        settings.downloads.maxConcurrent = 4

        #expect(AppSettings(defaults: store).downloads.maxConcurrent == 4)
    }

    /// A stored value outside `1...4` is CLAMPED rather than discarded: `9` means "as
    /// many as you can" and `0` means "one at a time", so answering either with the
    /// shipped default would throw away a stated intent. Absence is the only reading
    /// that means "never chose", and only it degrades to the default.
    @Test(
        "a stored concurrency outside the range clamps instead of resetting",
        arguments: [(9, 4), (5, 4), (0, 1), (-3, 1), (1, 1), (4, 4)]
    )
    func anOutOfRangeConcurrencyClamps(stored: Int, expected: Int) {
        let name = "\(Self.suitePrefix).concurrencyClamp.\(stored)"
        let store = Self.store(named: name)
        store.set(stored, forKey: "\(Self.downloadsPrefix)maxConcurrent")

        #expect(AppSettings(defaults: store).downloads.maxConcurrent == expected)
    }

    @Test("an absent or unreadable concurrency reads back as the shipped default")
    func anAbsentConcurrencyReadsTheDefault() {
        let absent = Self.store(named: "\(Self.suitePrefix).concurrencyAbsent")
        #expect(
            AppSettings(defaults: absent).downloads.maxConcurrent
                == DownloadQueueLimits.defaultConcurrentDownloads
        )

        let garbage = Self.store(named: "\(Self.suitePrefix).concurrencyGarbage")
        garbage.set("lots", forKey: "\(Self.downloadsPrefix)maxConcurrent")
        #expect(
            AppSettings(defaults: garbage).downloads.maxConcurrent
                == DownloadQueueLimits.defaultConcurrentDownloads
        )
    }

    @Test("the picker's choices span exactly the range the queue will honour")
    func theConcurrencyChoicesMatchTheQueueCeiling() {
        #expect(DownloadPreferences.concurrencyChoices == [1, 2, 3, 4])
        #expect(DownloadPreferences.concurrencyChoices.first == 1)
        #expect(DownloadPreferences.concurrencyChoices.last == DownloadQueueLimits.maxConcurrentDownloads)
        #expect(DownloadPreferences.concurrencyChoices.contains(DownloadQueueLimits.defaultConcurrentDownloads))
    }

    @Test("every download preference round-trips through a reload")
    func eachDownloadPreferenceRoundTrips() {
        let store = Self.store(named: "\(Self.suitePrefix).roundTrip")
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AppSettings(defaults: store)

        settings.downloads = DownloadPreferences(
            destinationPath: "/Users/listener/Music/Downloads",
            audioFormat: .flac,
            audioQuality: .medium,
            lastEngineUpdateCheck: checkedAt
        )

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.downloads.destinationPath == "/Users/listener/Music/Downloads")
        #expect(reloaded.downloads.audioFormat == .flac)
        #expect(reloaded.downloads.audioQuality == .medium)
        #expect(reloaded.downloads.lastEngineUpdateCheck == checkedAt)
    }

    @Test("mutating one field through the binding persists without disturbing the rest")
    func aFieldMutationPersistsOnItsOwn() {
        let store = Self.store(named: "\(Self.suitePrefix).fieldMutation")
        let settings = AppSettings(defaults: store)
        settings.downloads.destinationPath = "/Volumes/Media/YouTube"

        settings.downloads.audioFormat = .opus

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.downloads.audioFormat == .opus)
        #expect(reloaded.downloads.destinationPath == "/Volumes/Media/YouTube")
        #expect(reloaded.downloads.audioQuality == .best)
    }

    @Test("clearing the destination returns the default folder, not an empty path")
    func clearingTheDestinationReadsBackAsNil() {
        let store = Self.store(named: "\(Self.suitePrefix).clearedDestination")
        let settings = AppSettings(defaults: store)
        settings.downloads.destinationPath = "/tmp/downloads"

        settings.downloads.destinationPath = nil

        #expect(AppSettings(defaults: store).downloads.destinationPath == nil)
    }

    @Test("a garbage stored value degrades to the default instead of trapping")
    func garbagePersistedValuesDegrade() {
        let store = Self.store(named: "\(Self.suitePrefix).garbage")
        store.set("wav", forKey: "\(Self.downloadsPrefix)audioFormat")
        store.set(["best", "high"], forKey: "\(Self.downloadsPrefix)audioQuality")
        store.set(["path": 42], forKey: "\(Self.downloadsPrefix)destinationPath")
        store.set("not-a-date", forKey: "\(Self.downloadsPrefix)lastEngineUpdateCheck")

        let settings = AppSettings(defaults: store)
        #expect(settings.downloads.audioFormat == .m4a)
        #expect(settings.downloads.audioQuality == .best)
        #expect(settings.downloads.destinationPath == nil)
        #expect(settings.downloads.lastEngineUpdateCheck == nil)
    }

    @Test("one unreadable key leaves its neighbours intact")
    func aSingleGarbageKeyDoesNotResetTheOthers() {
        let store = Self.store(named: "\(Self.suitePrefix).partialGarbage")
        let settings = AppSettings(defaults: store)
        settings.downloads = DownloadPreferences(
            destinationPath: "/Users/listener/Music",
            audioFormat: .mp3,
            audioQuality: .high
        )

        store.set(["not", "a", "token"], forKey: "\(Self.downloadsPrefix)audioFormat")

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.downloads.audioFormat == .m4a)
        #expect(reloaded.downloads.destinationPath == "/Users/listener/Music")
        #expect(reloaded.downloads.audioQuality == .high)
    }

    @Test("downloads persist as six flat scalars, never as an encoded blob")
    func theStorageVocabularyIsFlatScalars() {
        let name = "\(Self.suitePrefix).flatKeys"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)

        settings.downloads = DownloadPreferences(
            destinationPath: "/Users/listener/Music",
            audioFormat: .mp3,
            audioQuality: .high,
            lastEngineUpdateCheck: Date(timeIntervalSince1970: 1_700_000_000),
            autoImportEnabled: true,
            maxConcurrent: 4
        )

        let domain = store.persistentDomain(forName: name) ?? [:]
        let persisted = domain.keys.filter { $0.hasPrefix(Self.downloadsPrefix) }.sorted()
        #expect(persisted == [
            "\(Self.downloadsPrefix)audioFormat",
            "\(Self.downloadsPrefix)audioQuality",
            "\(Self.downloadsPrefix)autoImportEnabled",
            "\(Self.downloadsPrefix)destinationPath",
            "\(Self.downloadsPrefix)lastEngineUpdateCheck",
            "\(Self.downloadsPrefix)maxConcurrent",
        ])
        for key in persisted {
            #expect(domain[key] as? Data == nil, "\(key) must persist a scalar, not an encoded blob")
        }
        #expect(store.string(forKey: "\(Self.downloadsPrefix)audioFormat") == "mp3")
        #expect(store.string(forKey: "\(Self.downloadsPrefix)audioQuality") == "high")
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.downloadPreferences"
    private static let downloadsPrefix = "com.example.macamp.settings.downloads."

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }
}
