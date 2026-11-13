// GeneratedPlaylistKind — what an auto-mix is, and when it goes stale.
//
// Two kinds ship. Both are POLICIES, not user-authored requests: the kind alone
// decides the candidate pool, the refresh interval and the feature bundle that
// gates it, so a refresh never has to read back what the previous one asked for.
// That is why ``GeneratedPlaylistSpec`` below is a RECORD of a refresh rather
// than an instruction for the next one — a shipped change to the target count
// takes effect immediately instead of being frozen into rows written months ago.
// A user-authored generated playlist (the assistant's) wants the opposite and
// must version its own payload; ``GeneratedPlaylistSpec/currentVersion`` is the
// seam for that.
//
// `rawValue` IS the stored `generatedPlaylist.generatorKind` string. Adding a
// case adds a kind; RENAMING one orphans every row already written under the old
// name. Treat these as persisted identifiers, not display names.
import Foundation

/// A generator that keeps one standing playlist per profile up to date.
public enum GeneratedPlaylistKind: String, Sendable, CaseIterable, Codable {
    /// The profile's tops for whichever daypart it is when the refresh runs.
    case daypartMix
    /// Tracks the profile engaged with and then stopped playing.
    case rediscovery
}

public extension GeneratedPlaylistKind {
    /// A daypart mix is stale after a day: by then the bucket it was built for
    /// has come round again, and the listening it summarises has moved.
    static let daypartRefreshInterval: TimeInterval = 24 * 60 * 60

    /// Rediscovery moves on the scale of the 90-day silence window that feeds it,
    /// so a weekly rebuild already outpaces its own input.
    static let rediscoveryRefreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Which of ``RediscoveryProviding``'s three lists the rediscovery auto-mix
    /// draws from.
    ///
    /// A PRODUCT choice, not a technical constraint. `forgottenFavourites` is the
    /// only one of the three backed by evidence that the listener already liked
    /// the track, which is what makes an unattended weekly mix worth pressing
    /// play on. `neverPlayed` proposes tracks with no evidence at all and
    /// `throwbacks` is seasonal — both are better as explicit, user-initiated
    /// lists than as the standing mix.
    static let rediscoveryList: RediscoveryList = .forgottenFavourites

    /// How long one materialisation of this kind stays fresh.
    var refreshInterval: TimeInterval {
        switch self {
        case .daypartMix: Self.daypartRefreshInterval
        case .rediscovery: Self.rediscoveryRefreshInterval
        }
    }

    /// The feature bundle whose toggle gates this kind.
    var bundle: AIFeatureBundle {
        switch self {
        case .daypartMix: .autoMixes
        case .rediscovery: .rediscovery
        }
    }

    /// The candidate pool a refresh of this kind draws from.
    ///
    /// `.daypart(part: nil)` deliberately leaves the bucket unresolved: the mix
    /// generator turns it into "whichever daypart it is now" at generation time
    /// through ``DaypartProviding/currentDaypart()``, so this service never
    /// computes a daypart of its own that could disagree with the draft's.
    var source: MixCandidateSource {
        switch self {
        case .daypartMix: .daypart(part: nil)
        case .rediscovery: .rediscovery(list: Self.rediscoveryList)
        }
    }

    /// The playlist name used when the composition root injects none.
    ///
    /// A generated playlist's name is DATA (the plan's decision — shells render it
    /// with `Text(verbatim:)`), and PlayerCore has no String Catalog, so this
    /// English fallback is what lands in `playlist.name` unless the shell supplies
    /// a localised name through ``GeneratedPlaylistService``'s `naming` closure.
    /// Wiring that is the composition root's job.
    var fallbackName: String {
        switch self {
        case .daypartMix: "Daily Mix"
        case .rediscovery: "Rediscover"
        }
    }
}

// MARK: - Stored spec

/// The versioned `generatedPlaylist.specJson` payload.
///
/// Encoded with `.sortedKeys`, so the stored bytes are a pure function of the
/// values and two refreshes with the same inputs produce the same row.
struct GeneratedPlaylistSpec: Codable, Equatable {
    /// Bumped when this payload's shape changes; written to
    /// `generatedPlaylist.specVersion`.
    static let currentVersion = 1

    /// ``GeneratedPlaylistKind/rawValue`` of the generator that ran.
    var kind: String
    /// The seed the ranking tie-breaks used — enough, with the kind and the
    /// library, to reproduce the draft.
    var seed: UInt64
    /// Tracks the refresh asked for (not necessarily the number it got).
    var targetCount: Int
    /// The rediscovery list used, for a rediscovery mix.
    var rediscoveryList: String?
    /// The daypart the draft was actually built for, resolved at generation time.
    var daypart: String?

    init(kind: GeneratedPlaylistKind, seed: UInt64, targetCount: Int, daypart: Daypart?) {
        self.kind = kind.rawValue
        self.seed = seed
        self.targetCount = targetCount
        rediscoveryList = kind == .rediscovery ? GeneratedPlaylistKind.rediscoveryList.rawValue : nil
        self.daypart = daypart?.rawValue
    }

    /// The payload as the `specJson` column holds it.
    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw GeneratedPlaylistError.specEncodingFailed(generatorKind: kind)
        }
        return json
    }
}

// MARK: - Seed

/// Derives the seed a refresh ranks with.
///
/// Never random: `(kind, profile, TTL window)` hashed with FNV-1a. Within one TTL
/// window a refresh is reproducible from the injected clock alone — which is what
/// makes an evidence run repeatable — and the NEXT window derives a different
/// seed, so a daily mix is not the same order every day when the underlying pool
/// has not moved. No timer is involved: the window is arithmetic on the instant
/// the caller's refresh happens to run at.
enum GeneratedPlaylistSeed {
    static func derive(kind: GeneratedPlaylistKind, profileId: Int64, at instant: Double) -> UInt64 {
        // `exactly:` rather than the trapping conversion — an absurd instant
        // must degrade to window 0, not crash a refresh.
        let elapsed = (max(0, instant) / kind.refreshInterval).rounded(.down)
        let window = Int64(exactly: elapsed) ?? 0
        return fnv1a("\(kind.rawValue):\(profileId):\(window)")
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}
