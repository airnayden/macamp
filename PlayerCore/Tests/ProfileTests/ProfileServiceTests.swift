import Foundation
import Persistence
import Services
import Testing

@MainActor
private final class ChangeLog {
    var profiles: [ProfileRecord] = []
    var count: Int {
        profiles.count
    }

    var last: ProfileRecord? {
        profiles.last
    }
}

@MainActor
private struct Harness {
    let service: ProfileService
    let repo: ProfileRepository
    let defaults: UserDefaults
    let suite: String

    func cleanup() {
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

@MainActor
@Suite("ProfileTests")
struct ProfileServiceTests {
    private func makeHarness() throws -> Harness {
        let appDB = try AppDatabase.makeEmpty()
        let repo = ProfileRepository(appDB)
        let suite = "test.profiles.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let service = ProfileService(profileRepository: repo, defaults: defaults)
        return Harness(service: service, repo: repo, defaults: defaults, suite: suite)
    }

    // MARK: - Switching + the change seam

    @Test("switching fires onActiveProfileChanged exactly once")
    func switchFiresOnce() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        let log = ChangeLog()
        harness.service.onActiveProfileChanged = { log.profiles.append($0) }

        try harness.service.switchTo(profileId: aliceId, pin: nil)

        #expect(log.count == 1)
        #expect(log.last?.id == aliceId)
        #expect(harness.service.activeProfile.id == aliceId)
    }

    @Test("re-selecting the already-active profile fires nothing")
    func reselectSameFiresNothing() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.switchTo(profileId: aliceId, pin: nil)

        let log = ChangeLog()
        harness.service.onActiveProfileChanged = { log.profiles.append($0) }
        try harness.service.switchTo(profileId: aliceId, pin: nil)

        #expect(log.count == 0)
        #expect(harness.service.activeProfile.id == aliceId)
    }

    @Test("active profile defaults to Guest")
    func defaultsToGuest() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        #expect(harness.service.activeProfile.id == ProfileRecord.guestID)
    }

    @Test("a new service restores the persisted active profile")
    func restoresPersistedActive() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.switchTo(profileId: aliceId, pin: nil)

        let restored = ProfileService(profileRepository: harness.repo, defaults: harness.defaults)
        #expect(restored.activeProfile.id == aliceId)
    }

    // MARK: - PIN gate

    @Test("wrong PIN throws .wrongPIN and does not switch")
    func wrongPINDoesNotSwitch() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.setPIN(profileId: aliceId, pin: "1234")
        let log = ChangeLog()
        harness.service.onActiveProfileChanged = { log.profiles.append($0) }

        #expect(throws: ProfileServiceError.wrongPIN) {
            try harness.service.switchTo(profileId: aliceId, pin: "0000")
        }
        #expect(harness.service.activeProfile.id == ProfileRecord.guestID)
        #expect(log.count == 0)
    }

    @Test("PIN attempts are unlimited: three wrong then correct succeeds")
    func unlimitedRetries() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.setPIN(profileId: aliceId, pin: "1234")

        for _ in 0 ..< 3 {
            #expect(throws: ProfileServiceError.wrongPIN) {
                try harness.service.switchTo(profileId: aliceId, pin: "9999")
            }
        }
        try harness.service.switchTo(profileId: aliceId, pin: "1234")
        #expect(harness.service.activeProfile.id == aliceId)
    }

    @Test("setPIN on Guest throws .guestPINForbidden")
    func setPINOnGuestForbidden() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        #expect(throws: ProfileServiceError.guestPINForbidden) {
            try harness.service.setPIN(profileId: ProfileRecord.guestID, pin: "1234")
        }
    }

    @Test("setPIN rejects a malformed PIN with .invalidPIN")
    func setPINRejectsInvalid() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        #expect(throws: ProfileServiceError.invalidPIN(.tooShort)) {
            try harness.service.setPIN(profileId: aliceId, pin: "12")
        }
    }

    @Test("removePIN nulls both pinHash and pinSalt")
    func removePINClearsColumns() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.setPIN(profileId: aliceId, pin: "1234")
        let gated = try #require(try harness.repo.profile(id: aliceId))
        #expect(gated.pinHash != nil)
        #expect(gated.pinSalt != nil)

        try harness.service.removePIN(profileId: aliceId)

        let cleared = try #require(try harness.repo.profile(id: aliceId))
        #expect(cleared.pinHash == nil)
        #expect(cleared.pinSalt == nil)
    }

    // MARK: - Delete

    @Test("deleting the active profile falls back to Guest and fires the seam")
    func deleteActiveFallsBackToGuest() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.switchTo(profileId: aliceId, pin: nil)
        let log = ChangeLog()
        harness.service.onActiveProfileChanged = { log.profiles.append($0) }

        try harness.service.delete(id: aliceId)

        #expect(harness.service.activeProfile.id == ProfileRecord.guestID)
        #expect(log.count == 1)
        #expect(log.last?.id == ProfileRecord.guestID)
    }

    @Test("create keeps the profiles mirror in sync")
    func createKeepsProfilesInSync() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        #expect(harness.service.profiles.count == 1)
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        #expect(harness.service.profiles.count == 2)
        #expect(harness.service.profiles.contains { $0.id == alice.id })
    }

    // MARK: - Enable / disable

    @Test("setEnabled(false) drops the active profile to Guest")
    func disableDropsToGuest() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.switchTo(profileId: aliceId, pin: nil)

        harness.service.setEnabled(false)

        #expect(harness.service.profilesEnabled == false)
        #expect(harness.service.activeProfile.id == ProfileRecord.guestID)
    }

    @Test("setEnabled(true) restores the last-active profile when it still exists")
    func enableRestoresLastActive() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.switchTo(profileId: aliceId, pin: nil)
        harness.service.setEnabled(false)

        harness.service.setEnabled(true)

        #expect(harness.service.profilesEnabled == true)
        #expect(harness.service.activeProfile.id == aliceId)
    }

    @Test("setEnabled(true) falls back to Guest when the last-active profile was deleted")
    func enableFallsBackWhenLastActiveDeleted() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let alice = try harness.service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try harness.service.switchTo(profileId: aliceId, pin: nil)
        harness.service.setEnabled(false)
        try harness.service.delete(id: aliceId)

        harness.service.setEnabled(true)

        #expect(harness.service.activeProfile.id == ProfileRecord.guestID)
    }
}
