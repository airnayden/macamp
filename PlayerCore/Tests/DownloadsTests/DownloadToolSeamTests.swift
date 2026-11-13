// The tool-provisioning and release-fetch seams, driven through their Fakes: the
// update lifecycle (up-to-date → available → applied) and the network half's
// URL→bytes map, both with zero disk and zero `URLSession`.
import Foundation
import PlayerCoreTestSupport
import Services
import Testing

@Suite("Download tool provider seam")
struct DownloadToolProviderSeamTests {
    @Test("a fresh provider reports its configured tools and version")
    func reportsConfiguredTools() async throws {
        let ytDlp = URL(fileURLWithPath: "/tmp/tools/yt-dlp")
        let ffmpeg = URL(fileURLWithPath: "/tmp/tools")
        let provider = FakeDownloadToolProvider(
            ytDlpURL: ytDlp,
            ffmpegDirectoryURL: ffmpeg,
            version: "2025.01.01"
        )
        #expect(try await provider.ytDlpURL == ytDlp)
        #expect(try await provider.ffmpegDirectoryURL == ffmpeg)
        #expect(try await provider.version() == "2025.01.01")
    }

    @Test("prepare is idempotent and counted")
    func prepareIsIdempotent() async throws {
        let provider = FakeDownloadToolProvider()
        try await provider.prepare()
        try await provider.prepare()
        #expect(provider.prepareCallCount == 2)
    }

    @Test("a provisioning failure blocks prepare and both tool URLs")
    func provisioningFailurePropagates() async {
        let provider = FakeDownloadToolProvider(prepareError: DownloadError.toolMissing)
        await #expect(throws: DownloadError.toolMissing) { try await provider.prepare() }
        await #expect(throws: DownloadError.toolMissing) { _ = try await provider.ytDlpURL }
        await #expect(throws: DownloadError.toolMissing) { _ = try await provider.ffmpegDirectoryURL }
        await #expect(throws: DownloadError.toolMissing) { _ = try await provider.version() }
    }

    @Test("an up-to-date engine offers no update")
    func upToDateOffersNothing() async throws {
        let provider = FakeDownloadToolProvider(version: "2025.01.01")
        let availability = try await provider.checkForUpdate()
        #expect(availability == .upToDate(version: "2025.01.01"))
        #expect(!availability.hasUpdate)
        #expect(availability.installedVersion == "2025.01.01")
    }

    @Test("applying an available update advances the reported version")
    func applyingUpdateAdvancesVersion() async throws {
        let provider = FakeDownloadToolProvider(
            version: "2025.01.01",
            update: .updateAvailable(installed: "2025.01.01", latest: "2025.02.02")
        )
        let before = try await provider.checkForUpdate()
        #expect(before.hasUpdate)
        #expect(before.installedVersion == "2025.01.01")

        let applied = try await provider.applyUpdate()
        #expect(applied == "2025.02.02")
        #expect(try await provider.version() == "2025.02.02")
        #expect(try await provider.checkForUpdate() == .upToDate(version: "2025.02.02"))
        #expect(provider.applyUpdateCallCount == 1)
    }

    @Test("a failed update throws and leaves the installed version alone")
    func failedUpdateKeepsInstalledVersion() async throws {
        let failure = DownloadError.updateFailed(detail: "checksum mismatch")
        let provider = FakeDownloadToolProvider(version: "2025.01.01", updateError: failure)
        await #expect(throws: failure) { _ = try await provider.applyUpdate() }
        #expect(try await provider.version() == "2025.01.01")
    }

    @Test("the offered update can be repointed mid-test")
    func updateCanBeRepointed() async throws {
        let provider = FakeDownloadToolProvider(version: "2025.01.01")
        #expect(try await provider.checkForUpdate().hasUpdate == false)
        provider.setUpdate(.updateAvailable(installed: "2025.01.01", latest: "2025.03.03"))
        #expect(try await provider.checkForUpdate().hasUpdate)
        #expect(provider.checkForUpdateCallCount == 2)
    }
}

@Suite("Tool release fetcher seam")
struct ToolReleaseFetcherSeamTests {
    @Test("the configured release is served and counted")
    func servesConfiguredRelease() async throws {
        let fetcher = FakeToolReleaseFetcher()
        let release = try await fetcher.fetchLatestRelease()
        #expect(release == FakeToolReleaseFetcher.sampleRelease)
        #expect(release.tag == "2025.02.02")
        #expect(fetcher.fetchLatestReleaseCallCount == 1)
    }

    @Test("payloads are served per URL and every fetch is recorded")
    func servesPayloadsPerURL() async throws {
        let release = FakeToolReleaseFetcher.sampleRelease
        let asset = Data("binary".utf8)
        let sums = Data("abc123  yt-dlp_macos".utf8)
        let fetcher = FakeToolReleaseFetcher(payloads: [release.assetURL: asset])
        fetcher.setPayload(sums, for: release.checksumURL)

        #expect(try await fetcher.fetchData(from: release.checksumURL) == sums)
        #expect(try await fetcher.fetchData(from: release.assetURL) == asset)
        #expect(fetcher.fetchedURLs == [release.checksumURL, release.assetURL])
    }

    @Test("an unconfigured URL fails rather than returning empty bytes")
    func unconfiguredURLFails() async throws {
        let fetcher = FakeToolReleaseFetcher()
        let missing = try downloadTestURL("https://fake.invalid/nothing")
        await #expect(throws: FakeToolReleaseFetcher.Failure.payloadMissing(missing)) {
            _ = try await fetcher.fetchData(from: missing)
        }
    }

    @Test("a feed failure propagates")
    func feedFailurePropagates() async {
        let fetcher = FakeToolReleaseFetcher(releaseError: DownloadError.updateFailed(detail: "offline"))
        await #expect(throws: DownloadError.updateFailed(detail: "offline")) {
            _ = try await fetcher.fetchLatestRelease()
        }
    }

    @Test("the served release can be repointed mid-test")
    func releaseCanBeRepointed() async throws {
        let fetcher = FakeToolReleaseFetcher()
        let newer = try ToolRelease(
            tag: "2025.09.09",
            assetURL: downloadTestURL("https://fake.invalid/new"),
            checksumURL: downloadTestURL("https://fake.invalid/new-sums")
        )
        fetcher.setRelease(newer)
        #expect(try await fetcher.fetchLatestRelease() == newer)
    }
}
