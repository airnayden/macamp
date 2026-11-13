// DownloadToolReleaseClient — the ONLY file in MacAMP's downloads surface that
// constructs a `URLSession`. `scripts/check-downloader-boundary.sh` exempts this path
// by name and nothing else.
//
// It is the network half of `DownloadToolProviding`, split out by todo 1 precisely so
// the interesting half — version comparison, checksum verification, atomic install,
// rollback — is driven by `DownloadToolManager` against `FakeToolReleaseFetcher` with
// zero I/O. Everything here is transport: one GitHub API read and one byte fetch.
//
// ── WHAT IS AND IS NOT VERIFIED HERE ─────────────────────────────────────────
//
// This type verifies TRANSPORT ONLY: HTTPS, a 2xx status, and a size ceiling. It does
// NOT verify the bytes it returns. The SHA-256 comparison against the release's own
// `SHA2-256SUMS` manifest is `DownloadToolManager`'s, and it happens BEFORE anything
// is swapped into place. Stated here so nobody reads "it came back 200" as "it is the
// binary we asked for".
//
// yt-dlp is the only tool that self-updates; ffmpeg/ffprobe ride app releases, so
// there is exactly one asset name and one manifest name to look for.
import Foundation
import os
import Services

/// Reads yt-dlp's published releases from the GitHub REST API.
final class DownloadToolReleaseClient: ToolReleaseFetching {
    /// The release asset for macOS: the ZIP of the universal (x86_64 + arm64)
    /// PyInstaller one-directory tree.
    ///
    /// NOT the bare `yt-dlp_macos` onefile asset published beside it in the same
    /// release. That one installs and runs, and costs ~12 s on every engine spawn for
    /// ever — see ``ToolUpdateInstaller``'s header. Every asset name in this file is
    /// matched EXACTLY, so the suffix is the whole difference.
    static let assetName = "yt-dlp_macos.zip"
    /// The checksum manifest published beside every release asset.
    static let checksumManifestName = "SHA2-256SUMS"
    /// A response larger than this is refused unread. The macOS archive is ~51 MB; the
    /// ceiling exists so a redirected or hostile URL cannot stream unbounded into
    /// memory behind a `Data`-returning API.
    static let maximumResponseBytes = 128 * 1024 * 1024

    private let latestReleaseURL: URL
    private let session: URLSession
    private let responseByteLimit: Int

    init(
        latestReleaseURL: URL = DownloadToolReleaseClient.defaultLatestReleaseURL,
        session: URLSession = DownloadToolReleaseClient.makeSession(),
        maximumResponseBytes: Int = DownloadToolReleaseClient.maximumResponseBytes
    ) {
        self.latestReleaseURL = latestReleaseURL
        precondition(maximumResponseBytes >= 0)
        self.session = session
        responseByteLimit = maximumResponseBytes
    }

    static var defaultLatestReleaseURL: URL {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else {
            fatalError("the yt-dlp release endpoint is a compile-time constant and must parse")
        }
        return url
    }

    /// A session that keeps nothing: an update check must not be answered from a cache
    /// that could hide a freshly published release, and no cookie or credential belongs
    /// on an anonymous public-API read.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    func fetchLatestRelease() async throws -> ToolRelease {
        let payload = try await fetch(latestReleaseURL, accept: "application/vnd.github+json")
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: payload)
        } catch {
            throw DownloadError.updateFailed(detail: "release feed was not the expected JSON")
        }
        guard let asset = release.asset(named: Self.assetName) else {
            throw DownloadError.updateFailed(detail: "release \(release.tagName) has no \(Self.assetName) asset")
        }
        guard let checksums = release.asset(named: Self.checksumManifestName) else {
            // Non-optional in `ToolRelease` on purpose: an asset whose bytes cannot be
            // verified is never installed, so a release without a manifest is not a
            // release this app can consume.
            throw DownloadError
                .updateFailed(detail: "release \(release.tagName) publishes no \(Self.checksumManifestName)")
        }
        return ToolRelease(tag: release.tagName, assetURL: asset, checksumURL: checksums)
    }

    func fetchData(from url: URL) async throws -> Data {
        try await fetch(url, accept: "application/octet-stream")
    }

    private func fetch(_ url: URL, accept: String) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw DownloadError.updateFailed(detail: "refusing a non-HTTPS release URL")
        }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // GitHub rejects an API request that does not identify itself.
        request.setValue("MacAMP", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            try Task.checkCancellation()
            return try await BoundedReleaseResponse(limit: responseByteLimit)
                .fetch(request, configuration: session.configuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as DownloadError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw DownloadError.updateFailed(detail: "could not reach \(url.host() ?? "the release feed")")
        }
    }
}

/// Enforces the bound in the transport callbacks, before retaining each chunk.
/// Each request owns its session so cancellation also releases its delegate.
private final class BoundedReleaseResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Data, any Error>?
        var session: URLSession?
        var data = Data()
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func fetch(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                let cancelled = state.withLock {
                    $0.continuation = continuation
                    $0.session = session
                    return $0.cancelled
                }
                if cancelled {
                    finish(.failure(CancellationError()))
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.state.withLock { $0.cancelled = true }
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(DownloadError.updateFailed(detail: "release feed answered HTTP \(http.statusCode)")))
        } else if response.expectedContentLength > Int64(limit) {
            completionHandler(.cancel)
            finish(.failure(DownloadError.updateFailed(detail: "release payload exceeded the size ceiling")))
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        let overflow = state.withLock { value in
            guard value.continuation != nil else { return false }
            guard data.count <= limit - value.data.count else { return true }
            value.data.append(data)
            return false
        }
        if overflow {
            finish(.failure(DownloadError.updateFailed(detail: "release payload exceeded the size ceiling")))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(state.withLock { $0.data }))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        let pending = state.withLock { value -> (CheckedContinuation<Data, any Error>, URLSession?)? in
            guard let continuation = value.continuation else { return nil }
            let session = value.session
            value.continuation = nil
            value.session = nil
            value.data = Data()
            return (continuation, session)
        }
        guard let (continuation, session) = pending else { return }
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
}

// MARK: - Wire shape

/// One downloadable file attached to a release.
///
/// A sibling of ``GitHubRelease`` rather than a nested type: its own `CodingKeys` would
/// otherwise sit three levels deep, past the `nesting` ceiling.
private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

/// The two fields of GitHub's release object this app reads. Everything else in that
/// payload is ignored, so an upstream addition cannot break decoding.
private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    func asset(named name: String) -> URL? {
        assets.first { $0.name == name }?.browserDownloadURL
    }
}
