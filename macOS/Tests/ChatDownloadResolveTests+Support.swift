// The rig for `ChatDownloadResolveTests`: a scripted resolver, the fixtures both halves
// of a mixed request are built from, and the two harness reads this suite needs.
//
// The resolver double installs itself into `AppEnvironment.resolveChatCandidates` — the
// SEAM production reads — rather than being passed to a hand-built graph, so every
// assertion runs against the shipped `handleChatDownloadRequest`. It records whole
// BATCHES rather than individual requests, because "one call for the whole press" is the
// property the suite exists to lock and a per-request recorder could not tell one call of
// two from two calls of one.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing

/// The songs the suite resolves, and the keys the table would draw them under.
///
/// Keys are spelled the way `LibraryChatSuggestionList.candidateKey(title:artist:)`
/// builds them (`"q:" + folded(title) + "|" + folded(artist ?? "")`) so a status written
/// here is addressable by exactly the string the real table would ask for.
enum ChatResolveFixtures {
    static let harrow = "Harrow"
    static let marrow = "Marrow"
    static let quarry = "Quarry"
    static let playlistName = "F3-QA"
    /// A third canonical id, so a mixed request's verified half cannot be confused with
    /// either half of its resolved one.
    static let verifiedID = "kJQP7kiw5Fk"

    static let harrowCandidate = ChatDownloadCandidate(key: "q:harrow|quarry", title: harrow, artist: quarry)
    static let marrowCandidate = ChatDownloadCandidate(key: "q:marrow|", title: marrow, artist: nil)

    static let candidatesOnlyRequest = ChatDownloadRequest(
        videoIDs: [],
        unresolved: [harrowCandidate],
        appendTarget: nil,
        appendProfileId: nil
    )
}

/// A scripted stand-in for the live `YouTubeLinkResolver`, keyed by song title.
@MainActor
final class ChatResolverDouble {
    /// Every batch the production path asked for, in order. The COUNT is the assertion.
    private(set) var batches: [[YouTubeLinkResolver.Request]] = []
    /// Title → the canonical video id it resolves to. An absent title resolves to `nil`,
    /// which is what an unresolvable song looks like.
    var answers: [String: String] = [:]
    /// Drops the last slot, so the "one slot per request IN ORDER" contract can be
    /// violated the way a misbehaving provider would violate it.
    var truncateAnswer = false

    /// Installs itself as the environment's resolution seam. The harness's environment
    /// keeps the reference, so this object lives as long as the test does.
    init(harness: ChatDownloadWiringHarness) {
        harness.environment.resolveChatCandidates = { [weak self] requests in
            self?.answer(requests) ?? []
        }
    }

    private func answer(_ requests: [YouTubeLinkResolver.Request]) -> [YouTubeLinkResolver.ResolvedVideo?] {
        batches.append(requests)
        let resolved = requests.map { request in
            answers[request.title].flatMap(Self.video)
        }
        return truncateAnswer ? Array(resolved.dropLast()) : resolved
    }

    private static func video(_ videoID: String) -> YouTubeLinkResolver.ResolvedVideo? {
        guard let url = YouTubeURLNormalizer.canonicalURL(forVideoID: videoID) else { return nil }
        return YouTubeLinkResolver.ResolvedVideo(videoId: videoID, url: url, canonicalTitle: videoID)
    }
}

extension ChatDownloadWiringHarness {
    /// What the suggestion table would render for `key` — a canonical video id or a
    /// `"q:"` candidate key, which the store answers identically by design.
    func status(_ key: String) -> ChatDownloadRowStatus {
        environment.chatDownloadStatus.status(for: key)
    }

    /// Seeds one completed-download row, so the advisory history lookup has something to
    /// find. Only `canonicalVideoID` is read by `knownVideoIDs(in:)`; the rest is the
    /// minimum a valid row carries.
    func recordHistory(videoID: String) async throws {
        try await DownloadHistoryRepository(database).insert(DownloadHistoryRecord(
            id: UUID().uuidString,
            canonicalVideoID: videoID,
            filePath: destination.appendingPathComponent("\(videoID).m4a").path,
            audioFormat: DownloadAudioFormat.m4a.rawValue,
            audioQuality: DownloadAudioQuality.best.rawValue,
            sourceURL: "https://www.youtube.com/watch?v=\(videoID)",
            downloadedAt: Date().timeIntervalSince1970,
            utcOffsetSeconds: 0
        ))
    }
}
