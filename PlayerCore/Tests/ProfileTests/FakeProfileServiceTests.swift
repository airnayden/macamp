import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("ProfileTests")
struct FakeProfileServiceTests {
    @Test("seeds Guest and defaults active to Guest")
    func seedsGuest() {
        let service = FakeProfileService()
        #expect(service.activeProfile.id == ProfileRecord.guestID)
        #expect(service.profiles.contains { $0.id == ProfileRecord.guestID })
    }

    @Test("switching fires the seam once and re-selecting fires nothing")
    func switchFires() throws {
        let service = FakeProfileService()
        let alice = try service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        var fired: [Int64] = []
        service.onActiveProfileChanged = { fired.append($0.id ?? -1) }

        try service.switchTo(profileId: aliceId, pin: nil)
        try service.switchTo(profileId: aliceId, pin: nil)

        #expect(fired == [aliceId])
        #expect(service.activeProfile.id == aliceId)
    }

    @Test("wrong PIN throws and delete of active falls back to Guest")
    func pinAndDelete() throws {
        let service = FakeProfileService()
        let alice = try service.create(ProfileRecord(name: "Alice"))
        let aliceId = try #require(alice.id)
        try service.setPIN(profileId: aliceId, pin: "1234")

        #expect(throws: ProfileServiceError.wrongPIN) {
            try service.switchTo(profileId: aliceId, pin: "0000")
        }
        try service.switchTo(profileId: aliceId, pin: "1234")
        #expect(service.activeProfile.id == aliceId)

        try service.delete(id: aliceId)
        #expect(service.activeProfile.id == ProfileRecord.guestID)
    }

    @Test("Guest is undeletable")
    func guestUndeletable() {
        let service = FakeProfileService()
        #expect(throws: ProfileRepositoryError.guestUndeletable) {
            try service.delete(id: ProfileRecord.guestID)
        }
    }
}
