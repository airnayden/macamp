// ProfileService — the session state machine over the profile store.
//
// `ProfileService` is the single `@MainActor` source of truth for "who is the
// active profile" and "is the profiles feature on". It owns the switch / create /
// update / delete / PIN lifecycle on top of an injected
// ``ProfileRepositoryProviding`` (todo 2) plus the salted-PIN primitives in
// ``ProfilePIN`` (todo 3), and persists the two ids it needs to survive relaunch
// (`activeProfileId`, `lastActiveProfileId`) into an injected `UserDefaults`
// suite.
//
// ## Deliberate non-goals (do NOT add these — out of scope by product decision)
//   * No session auto-lock, timeout, or idle expiry. A session ends only when the
//     user switches profile or disables the feature.
//   * No PIN retry cap, lockout, or backoff — unlimited attempts BY DESIGN (the
//     PIN is soft child-proofing, see ``ProfilePIN``'s threat model).
//   * No bare database connection — every read/write funnels through the injected
//     repository protocol. This file also MUST NOT import AppKit or UIKit
//     (PlayerCore portability invariant).
//
// ## Persistence contract (todo 5 wires the SAME `UserDefaults` suite — these two
// keys are the collision-avoidance contract):
//   * `com.macamp.profiles.activeProfileId`     — restored as `activeProfile` at
//     launch (falls back to Guest when absent, nil, or pointing at a deleted row).
//   * `com.macamp.profiles.lastActiveProfileId` — who was active before the
//     feature was disabled, so re-enabling can restore them.
// `profilesEnabled` is an in-memory MIRROR only — todo 5 owns the persisted
// feature flag and drives it in via `setEnabled(_:)`; this service never persists
// it.
//
// The PIN salt is stored on the profile row (`pinSalt`) as a Base64 string; this
// file OWNS that encoding, so every PIN write/verify goes through here.
import Foundation
import Observation
import Persistence

/// A typed reason a ``ProfileService`` operation failed.
///
/// `invalidPIN` carries the specific ``ProfilePINError`` from
/// ``ProfilePIN/validate(_:)`` (as an associated value) so the editor UI can show
/// the precise reason — too short / too long / bad characters — rather than a
/// generic message.
public enum ProfileServiceError: Error, Sendable, Equatable {
    /// The supplied PIN did not match the target profile's stored hash. There is
    /// no retry cap — the caller may try again immediately.
    case wrongPIN
    /// A PIN was set on the built-in Guest profile, which may never carry one.
    case guestPINForbidden
    /// The candidate PIN was malformed; the associated value is the specific
    /// validation failure from ``ProfilePIN/validate(_:)``.
    case invalidPIN(ProfilePINError)
}

/// The session/profile-management surface the rest of the app builds against.
///
/// Class-bound + `@MainActor`: profile state is UI state, mutated only on the
/// main actor. Every method is synchronous, matching the sync-only repository
/// (todo 2); a caller that must not block wraps the call in `Task.detached`.
@MainActor
public protocol ProfileManaging: AnyObject {
    /// Every profile, Guest first (mirrors the repository ordering).
    var profiles: [ProfileRecord] { get }
    /// The currently active profile. Defaults to Guest (``ProfileRecord/guestID``).
    var activeProfile: ProfileRecord { get }
    /// Whether the profiles feature is enabled. A mirror of an external flag.
    var profilesEnabled: Bool { get }
    /// Fired on every *real* active-profile change — the re-observation seam that
    /// re-scopes profile-owned queries. NOT fired when the same profile is
    /// re-selected.
    var onActiveProfileChanged: ((ProfileRecord) -> Void)? { get set }

    /// Switches the active profile, verifying `pin` when the target has one set.
    /// Throws ``ProfileServiceError/wrongPIN`` on mismatch (without switching).
    func switchTo(profileId: Int64, pin: String?) throws
    /// Creates a profile and returns it with its assigned id.
    @discardableResult func create(_ profile: ProfileRecord) throws -> ProfileRecord
    /// Persists edits to an existing profile.
    func update(_ profile: ProfileRecord) throws
    /// Deletes a profile; deleting the active one falls back to Guest.
    func delete(id: Int64) throws
    /// Sets (or replaces) a profile's PIN. Forbidden on Guest.
    func setPIN(profileId: Int64, pin: String) throws
    /// Clears a profile's PIN (nulls both hash and salt).
    func removePIN(profileId: Int64) throws
    /// Enables/disables the feature, toggling the active profile accordingly.
    func setEnabled(_ enabled: Bool)
    /// Re-reads the roster from storage.
    ///
    /// Needed after a write that bypassed this service: importing a
    /// `.macampprofile` inserts its profile row inside the archive's own
    /// transaction, so nothing here would otherwise know the roster changed.
    func reload()
}

/// The production ``ProfileManaging`` over a repository + a `UserDefaults` suite.
@MainActor
@Observable
public final class ProfileService: ProfileManaging {
    public private(set) var profiles: [ProfileRecord] = []
    public private(set) var activeProfile: ProfileRecord
    public private(set) var profilesEnabled = false

    @ObservationIgnored
    public var onActiveProfileChanged: ((ProfileRecord) -> Void)?

    @ObservationIgnored private let repository: any ProfileRepositoryProviding
    @ObservationIgnored private let defaults: UserDefaults

    /// Creates a service bound to `profileRepository`, restoring the persisted
    /// active profile from `defaults` (falling back to Guest when the stored id is
    /// absent, nil, or points at a deleted profile).
    public init(profileRepository: any ProfileRepositoryProviding, defaults: UserDefaults) {
        repository = profileRepository
        self.defaults = defaults
        activeProfile = ProfileService.syntheticGuest
        reloadProfiles()
        activeProfile = resolvePersistedActiveProfile()
    }
}

// MARK: - Mutations

public extension ProfileService {
    func switchTo(profileId: Int64, pin: String?) throws {
        // Re-selecting the already-active profile is a no-op — fires nothing and
        // skips PIN verification entirely.
        guard profileId != activeProfile.id else { return }
        // An unknown id is a caller/UI error, not a modelled failure — no-op.
        guard let target = lookup(profileId) else { return }
        try verifyPIN(pin, for: target)
        activate(target)
    }

    @discardableResult
    func create(_ profile: ProfileRecord) throws -> ProfileRecord {
        let created = try repository.create(profile)
        reloadProfiles()
        return created
    }

    func update(_ profile: ProfileRecord) throws {
        try repository.update(profile)
        reloadProfiles()
        // A field edit is NOT a switch: refresh the cached active copy but never
        // fire `onActiveProfileChanged`.
        if let id = profile.id, id == activeProfile.id {
            activeProfile = profiles.first { $0.id == id } ?? profile
        }
    }

    func delete(id: Int64) throws {
        // The repository rejects the Guest id with `ProfileRepositoryError`
        // .guestUndeletable — let that propagate unchanged.
        try repository.delete(id: id)
        reloadProfiles()
        if id == activeProfile.id {
            activate(fetchGuest())
        }
    }

    func setPIN(profileId: Int64, pin: String) throws {
        guard profileId != ProfileRecord.guestID else {
            throw ProfileServiceError.guestPINForbidden
        }
        if case let .failure(error) = ProfilePIN.validate(pin) {
            throw ProfileServiceError.invalidPIN(error)
        }
        guard var target = lookup(profileId) else { return }
        let salt = ProfilePIN.makeSalt()
        target.pinHash = ProfilePIN.hash(pin: pin, salt: salt)
        target.pinSalt = encodeSalt(salt)
        try persistEdited(target)
    }

    func removePIN(profileId: Int64) throws {
        guard var target = lookup(profileId) else { return }
        target.pinHash = nil
        target.pinSalt = nil
        try persistEdited(target)
    }

    func reload() {
        reloadProfiles()
    }

    func setEnabled(_ enabled: Bool) {
        profilesEnabled = enabled
        if enabled {
            restoreLastActiveProfile()
        } else {
            // Remember who was active BEFORE switching, so re-enabling restores
            // them, then drop to Guest.
            persist(activeProfile.id, forKey: ProfileService.lastActiveProfileIdKey)
            activate(fetchGuest())
        }
    }
}

// MARK: - Session helpers

private extension ProfileService {
    /// UserDefaults key holding the active profile's id (restored at launch).
    static let activeProfileIdKey = "com.macamp.profiles.activeProfileId"
    /// UserDefaults key holding who was active before the feature was disabled.
    static let lastActiveProfileIdKey = "com.macamp.profiles.lastActiveProfileId"

    /// A defensive Guest row used before the store is consulted and if the seeded
    /// Guest row is ever unreadable. The `v12` migration always seeds the real one.
    static var syntheticGuest: ProfileRecord {
        ProfileRecord(id: ProfileRecord.guestID, name: "Guest")
    }

    func reloadProfiles() {
        // Keep the existing list on a transient read error rather than blanking it.
        profiles = (try? repository.allProfiles(limit: ProfileRepository.fetchLimit)) ?? profiles
    }

    func resolvePersistedActiveProfile() -> ProfileRecord {
        guard let storedId = persistedActiveProfileId, let profile = lookup(storedId) else {
            return fetchGuest()
        }
        return profile
    }

    /// Restores the profile active before the feature was disabled, or Guest when
    /// that profile no longer exists.
    func restoreLastActiveProfile() {
        guard let lastId = persistedLastActiveProfileId, let profile = lookup(lastId) else {
            activate(fetchGuest())
            return
        }
        activate(profile)
    }

    /// Commits `profile` as active, persists its id, and fires the change seam
    /// ONLY when the active identity actually changed.
    func activate(_ profile: ProfileRecord) {
        let changed = profile.id != activeProfile.id
        activeProfile = profile
        persist(profile.id, forKey: ProfileService.activeProfileIdKey)
        if changed {
            onActiveProfileChanged?(profile)
        }
    }

    /// Verifies `candidate` against `profile`'s stored PIN. A profile with no PIN
    /// always passes; a set PIN that is missing/undecodable/wrong throws.
    func verifyPIN(_ candidate: String?, for profile: ProfileRecord) throws {
        guard let hash = profile.pinHash else { return }
        guard let saltString = profile.pinSalt,
              let salt = decodeSalt(saltString),
              let candidate,
              ProfilePIN.verify(pin: candidate, hash: hash, salt: salt)
        else {
            throw ProfileServiceError.wrongPIN
        }
    }

    /// Persists an edited profile row and refreshes cached state (used by the PIN
    /// mutators). Not a switch — never fires `onActiveProfileChanged`.
    func persistEdited(_ profile: ProfileRecord) throws {
        try repository.update(profile)
        reloadProfiles()
        if profile.id == activeProfile.id {
            activeProfile = profile
        }
    }

    func fetchGuest() -> ProfileRecord {
        lookup(ProfileRecord.guestID) ?? ProfileService.syntheticGuest
    }

    func lookup(_ id: Int64) -> ProfileRecord? {
        (try? repository.profile(id: id)) ?? nil
    }

    // MARK: Persisted ids

    var persistedActiveProfileId: Int64? {
        readId(forKey: ProfileService.activeProfileIdKey)
    }

    var persistedLastActiveProfileId: Int64? {
        readId(forKey: ProfileService.lastActiveProfileIdKey)
    }

    /// Reads a stored id, treating the UserDefaults "0 means absent" default as nil
    /// (profile rowids are always positive).
    func readId(forKey key: String) -> Int64? {
        let raw = defaults.integer(forKey: key)
        return raw == 0 ? nil : Int64(raw)
    }

    func persist(_ id: Int64?, forKey key: String) {
        if let id {
            defaults.set(Int(id), forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Salt <-> String

    func encodeSalt(_ salt: Data) -> String {
        salt.base64EncodedString()
    }

    func decodeSalt(_ string: String) -> Data? {
        Data(base64Encoded: string)
    }
}
