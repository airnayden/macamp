// ThemePresetMigrationTests — MacAMP collapsed ten skins to one, and the ten
// retired ids are still sitting in every existing install's `UserDefaults` and in
// every `.macampprofile` archive exported before the change.
//
// Two failure modes this pins, both of which are invisible in the UI:
//   * `AppSettings` hydrates its stored properties in `init`, where `didSet` never
//     fires. A migration that assigns `.macAMP` without an EXPLICIT `defaults.set`
//     leaves the stale string on disk forever, so nothing is actually migrated.
//   * `PortableSettingsMapping` otherwise IGNORES unrecognised raw values by
//     design. Left on that path a legacy archive's skin field is silently dropped.
import Foundation
@testable import MacAMP
import Persistence
import Testing

/// Every raw value that shipped before the collapse, plus values a hand-edited
/// plist could hold.
///
/// File scope, not a member: `@Test(arguments:)` evaluates its collection outside
/// the suite's `@MainActor` isolation, so a static property on this suite is
/// unreachable from the generated test case.
private let legacyRawValues = [
    "viceCity", "purple", "blue", "green", "midnight",
    "red", "orange", "cyan", "pink", "yellow",
    "zzz", "",
]

@Suite("Theme preset migration")
@MainActor
struct ThemePresetMigrationTests {
    @Test("a stored legacy or unknown skin id resolves to macAMP", arguments: legacyRawValues)
    func legacyValueResolvesToMacAMP(stored: String) {
        let store = Self.store(named: "\(Self.suitePrefix).resolve.\(stored.isEmpty ? "empty" : stored)")
        store.set(stored, forKey: Self.themePresetKey)

        let settings = AppSettings(defaults: store)

        #expect(settings.themePreset == .macAMP)
    }

    @Test("the migration is written back to disk, not just resolved in memory", arguments: legacyRawValues)
    func legacyValueIsRewrittenOnDisk(stored: String) {
        let name = "\(Self.suitePrefix).writeback.\(stored.isEmpty ? "empty" : stored)"
        let store = Self.store(named: name)
        store.set(stored, forKey: Self.themePresetKey)

        _ = AppSettings(defaults: store)

        #expect(store.string(forKey: Self.themePresetKey) == "macAMP")
    }

    @Test("a missing stored value migrates too")
    func absentValueIsWrittenBack() {
        let store = Self.store(named: "\(Self.suitePrefix).absent")
        #expect(store.string(forKey: Self.themePresetKey) == nil)

        let settings = AppSettings(defaults: store)

        #expect(settings.themePreset == .macAMP)
        #expect(store.string(forKey: Self.themePresetKey) == "macAMP")
    }

    @Test("an already-migrated value survives a reload unchanged")
    func migratedValueIsStable() {
        let store = Self.store(named: "\(Self.suitePrefix).stable")
        store.set("macAMP", forKey: Self.themePresetKey)

        _ = AppSettings(defaults: store)
        let reloaded = AppSettings(defaults: store)

        #expect(reloaded.themePreset == .macAMP)
        #expect(store.string(forKey: Self.themePresetKey) == "macAMP")
    }

    @Test("MacAMP ships exactly one skin")
    func exactlyOnePreset() {
        #expect(ThemePreset.allCases == [.macAMP])
        #expect(ThemePreset.macAMP.rawValue == "macAMP")
        #expect(ThemePreset.macAMP.id == "macAMP")
    }

    // MARK: Archive round-trip

    @Test("importing an archive that names a retired skin applies macAMP", arguments: legacyRawValues)
    func archiveImportMigratesLegacySkin(archived: String) {
        let store = Self.store(named: "\(Self.suitePrefix).import.\(archived.isEmpty ? "empty" : archived)")
        let settings = AppSettings(defaults: store)

        PortableSettings(themePreset: archived).apply(to: settings)

        #expect(settings.themePreset == .macAMP)
    }

    @Test("an archive that carried no skin leaves the preference alone")
    func archiveWithoutSkinIsInert() {
        let store = Self.store(named: "\(Self.suitePrefix).importAbsent")
        let settings = AppSettings(defaults: store)

        PortableSettings(themePreset: nil).apply(to: settings)

        #expect(settings.themePreset == .macAMP)
    }

    @Test("export writes the current skin id")
    func exportWritesMacAMP() {
        let store = Self.store(named: "\(Self.suitePrefix).export")
        let settings = AppSettings(defaults: store)

        #expect(PortableSettings(settings).themePreset == "macAMP")
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.themePreset"
    private static let themePresetKey = "com.example.macamp.settings.themePreset"

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }
}
