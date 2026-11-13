// FakeProfileService — an in-memory ``ProfileManaging`` for previews and tests.
//
// A deterministic, dependency-free stand-in for `ProfileService`: no
// `UserDefaults`, no repository, no hashing. Profile rows live in a plain array
// and PINs are held as PLAINTEXT in a side dictionary (the Fake stores no
// hashes). It mirrors the real service's session state machine — Guest fallback
// on delete/disable, last-active restore on enable, and the "fire the seam only
// on a real switch" rule — so downstream view-model / UI tests (todos 14–18) can
// inject profile state without touching GRDB or UserDefaults.
//
// Style mirrors `FakePlaybackEngine`: a `@MainActor` final class driving the same
// protocol with a synchronous in-memory state machine.
//
// Fidelity note: the PIN gate is driven by `setPIN` (the plaintext `pins` map),
// NOT by any `pinHash` preset on a seeded record. Seed a `pins` entry via
// `setPIN` when a test needs a PIN-gated profile.
import Foundation
import Observation
import Persistence
import Services

/// An in-memory ``ProfileManaging`` for hermetic tests and SwiftUI previews.
@MainActor
@Observable
public final class FakeProfileService: ProfileManaging {
    public private(set) var profiles: [ProfileRecord]
    public private(set) var activeProfile: ProfileRecord
    public private(set) var profilesEnabled: Bool

    @ObservationIgnored
    public var onActiveProfileChanged: ((ProfileRecord) -> Void)?

    /// Plaintext PINs by profile id. The Fake performs no hashing — a profile is
    /// PIN-gated iff it has an entry here.
    @ObservationIgnored private var pins: [Int64: String] = [:]
    @ObservationIgnored private var lastActiveProfileId: Int64?
    @ObservationIgnored private var nextId: Int64

    /// A synthetic Guest row (id 1) matching what the `v12` migration seeds.
    public static var guest: ProfileRecord {
        ProfileRecord(id: ProfileRecord.guestID, name: "Guest")
    }

    /// Creates a Fake seeded with `profiles` (Guest is inserted if absent) and an
    /// optional starting `active` profile (defaults to Guest).
    public init(
        profiles: [ProfileRecord] = [FakeProfileService.guest],
        active: ProfileRecord? = nil,
        profilesEnabled: Bool = false
    ) {
        var seeded = profiles
        if !seeded.contains(where: { $0.id == ProfileRecord.guestID }) {
            seeded.insert(FakeProfileService.guest, at: 0)
        }
        self.profiles = seeded
        activeProfile = active ?? seeded.first { $0.id == ProfileRecord.guestID } ?? FakeProfileService.guest
        self.profilesEnabled = profilesEnabled
        nextId = (seeded.compactMap(\.id).max() ?? ProfileRecord.guestID) + 1
    }
}

// MARK: - Mutations

public extension FakeProfileService {
    func switchTo(profileId: Int64, pin: String?) throws {
        guard profileId != activeProfile.id else { return }
        guard let target = profiles.first(where: { $0.id == profileId }) else { return }
        if let required = pins[profileId], pin != required {
            throw ProfileServiceError.wrongPIN
        }
        commit(target)
    }

    @discardableResult
    func create(_ profile: ProfileRecord) throws -> ProfileRecord {
        var copy = profile
        if copy.id == nil {
            copy.id = nextId
            nextId += 1
        }
        profiles.append(copy)
        return copy
    }

    func update(_ profile: ProfileRecord) throws {
        guard let id = profile.id, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index] = profile
        if id == activeProfile.id { activeProfile = profile }
    }

    func delete(id: Int64) throws {
        guard id != ProfileRecord.guestID else {
            throw ProfileRepositoryError.guestUndeletable
        }
        profiles.removeAll { $0.id == id }
        pins[id] = nil
        if id == activeProfile.id { commit(guestProfile()) }
    }

    func setPIN(profileId: Int64, pin: String) throws {
        guard profileId != ProfileRecord.guestID else {
            throw ProfileServiceError.guestPINForbidden
        }
        if case let .failure(error) = ProfilePIN.validate(pin) {
            throw ProfileServiceError.invalidPIN(error)
        }
        pins[profileId] = pin
        markPINState(profileId, hasPIN: true)
    }

    func removePIN(profileId: Int64) throws {
        pins[profileId] = nil
        markPINState(profileId, hasPIN: false)
    }

    /// The roster IS the storage here, so there is nothing to re-read.
    func reload() {}

    func setEnabled(_ enabled: Bool) {
        profilesEnabled = enabled
        if enabled {
            if let lastId = lastActiveProfileId, let profile = profiles.first(where: { $0.id == lastId }) {
                commit(profile)
            } else {
                commit(guestProfile())
            }
        } else {
            lastActiveProfileId = activeProfile.id
            commit(guestProfile())
        }
    }
}

// MARK: - Helpers

private extension FakeProfileService {
    /// Sets `profile` active and fires the seam only on a real identity change.
    func commit(_ profile: ProfileRecord) {
        guard profile.id != activeProfile.id else { return }
        activeProfile = profile
        onActiveProfileChanged?(profile)
    }

    func guestProfile() -> ProfileRecord {
        profiles.first { $0.id == ProfileRecord.guestID } ?? FakeProfileService.guest
    }

    /// Reflects "has a PIN" on the record with opaque markers (the Fake keeps the
    /// real plaintext in `pins`), so UI that checks `pinHash != nil` behaves.
    func markPINState(_ profileId: Int64, hasPIN: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        var updated = profiles[index]
        updated.pinHash = hasPIN ? "fake-hash" : nil
        updated.pinSalt = hasPIN ? "fake-salt" : nil
        profiles[index] = updated
        if profileId == activeProfile.id { activeProfile = updated }
    }
}
