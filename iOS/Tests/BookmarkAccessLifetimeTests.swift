import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Library root access lifetime")
@MainActor
struct BookmarkAccessLifetimeTests {
    @Test("ending a token twice releases a successful grant only once")
    func tokenEndIsIdempotent() {
        let resource = CountingSecurityScopedResource()
        let token = beginSecurityScopedAccess(to: [resource])
        token.end()
        token.end()
        #expect(resource.startCount == 1)
        #expect(resource.stopCount == 1)
    }

    @Test("imported roots remain accessible after the importer is gone")
    func accessOutlivesImporter() async {
        let resource = CountingSecurityScopedResource()
        var owner: SecurityScopedAccessOwner? = SecurityScopedAccessOwner(resource: { _ in resource })
        if let owner {
            await runImport(owner: owner)
        }
        #expect(resource.startCount == 1)
        #expect(resource.stopCount == 0)
        owner = nil
        #expect(resource.stopCount == 1)
    }

    @Test("restored roots acquire access before an importer exists and deduplicate paths")
    func restoresAndDeduplicatesRoots() {
        let resource = CountingSecurityScopedResource()
        let root = URL(fileURLWithPath: "/fixture/music")
        var owner: SecurityScopedAccessOwner? = SecurityScopedAccessOwner(roots: [root], resource: { _ in resource })
        #expect(resource.startCount == 1)
        owner?.retainAccess(to: [root, URL(fileURLWithPath: "/fixture/other/../music")])
        #expect(resource.startCount == 1)
        #expect(resource.stopCount == 0)
        owner = nil
        #expect(resource.stopCount == 1)
    }

    @Test("a denied grant is retried and only successful starts are stopped")
    func retriesDeniedGrant() {
        let resource = RetryScopedResource()
        let root = URL(fileURLWithPath: "/fixture/music")
        var owner: SecurityScopedAccessOwner? = SecurityScopedAccessOwner(roots: [root], resource: { _ in resource })
        #expect(resource.startCount == 1)
        #expect(resource.stopCount == 0)
        owner?.retainAccess(to: [root])
        owner?.retainAccess(to: [root])
        #expect(resource.startCount == 2)
        #expect(resource.stopCount == 0)
        owner = nil
        #expect(resource.stopCount == 1)
    }

    private func runImport(owner: SecurityScopedAccessOwner) async {
        let importer = DocumentImporter(
            scanner: FakeLibraryScanner(),
            bookmarks: SecurityScopedBookmarkManager(store: InMemoryBookmarkStore()),
            accessOwner: owner,
            materializer: NoFileMaterialization()
        )
        await importer.importPicked([URL(fileURLWithPath: "/fixture-unavailable/audio.flac")])
    }
}

private struct NoFileMaterialization: FileMaterializing {
    func materialize(_: URL) async {}
    func materializeContents(of _: URL) async {}
}

private final class RetryScopedResource: SecurityScopedResource {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func startAccessingSecurityScopedResource() -> Bool {
        startCount += 1
        return startCount > 1
    }

    func stopAccessingSecurityScopedResource() {
        stopCount += 1
    }
}
