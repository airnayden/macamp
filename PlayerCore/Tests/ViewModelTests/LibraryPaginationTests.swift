// LibraryPaginationTests — the threshold-prefetch rule and the one-in-flight gate
// that together decide when a paginated track list fetches its next page.
//
// These are the pure half of the library browser's pagination: the macOS shell
// supplies the row index and the fetch, everything decided here is testable
// without SwiftUI.
import Testing
import ViewModels

@Suite("Library prefetch threshold")
struct LibraryPaginationThresholdTests {
    @Test("a row inside the threshold window prefetches")
    func rowNearTheEndPrefetches() {
        #expect(LibraryPagination.shouldPrefetch(index: 80, count: 100))
        #expect(LibraryPagination.shouldPrefetch(index: 99, count: 100))
    }

    @Test("a row far from the end does not prefetch")
    func rowFarFromTheEndDoesNotPrefetch() {
        #expect(!LibraryPagination.shouldPrefetch(index: 0, count: 100))
        #expect(!LibraryPagination.shouldPrefetch(index: 10, count: 100))
    }

    @Test("the threshold boundary is inclusive")
    func thresholdBoundaryIsInclusive() {
        // count - index == 25 -> exactly at the threshold, still prefetches.
        #expect(LibraryPagination.shouldPrefetch(index: 75, count: 100))
        // count - index == 26 -> one row too early.
        #expect(!LibraryPagination.shouldPrefetch(index: 74, count: 100))
    }

    @Test("every row of a window shorter than the threshold prefetches")
    func tinyWindowsAlwaysPrefetch() {
        #expect(LibraryPagination.shouldPrefetch(index: 0, count: 1))
        #expect(LibraryPagination.shouldPrefetch(index: 0, count: 3))
        #expect(LibraryPagination.shouldPrefetch(index: 2, count: 3))
        #expect(LibraryPagination.shouldPrefetch(index: 0, count: 25))
    }

    @Test("an index outside the loaded window never prefetches")
    func outOfRangeIndexDoesNotPrefetch() {
        #expect(!LibraryPagination.shouldPrefetch(index: -1, count: 100))
        #expect(!LibraryPagination.shouldPrefetch(index: 100, count: 100))
        #expect(!LibraryPagination.shouldPrefetch(index: 0, count: 0))
    }

    @Test("a custom threshold overrides the default")
    func customThresholdApplies() {
        #expect(LibraryPagination.shouldPrefetch(index: 90, count: 100, threshold: 10))
        #expect(!LibraryPagination.shouldPrefetch(index: 80, count: 100, threshold: 10))
        // A threshold below 1 is clamped, so the last row still triggers.
        #expect(LibraryPagination.shouldPrefetch(index: 99, count: 100, threshold: 0))
        #expect(!LibraryPagination.shouldPrefetch(index: 98, count: 100, threshold: 0))
    }

    @Test("the viewport fill is bounded")
    func viewportFillIsBounded() {
        #expect(LibraryPagination.viewportFillMaxPages == 3)
        #expect(LibraryPagination.viewportFillTarget == 150)
        #expect(LibraryPagination.prefetchThreshold == 25)
    }
}

/// Counts the page fetches a simulated scroll burst actually issued.
@MainActor
private final class FetchCounter {
    var count = 0
}

@Suite("Library prefetch gate")
@MainActor
struct LibraryPrefetchGateTests {
    @Test("a burst of row appearances issues exactly one page fetch")
    func burstOfAppearancesIssuesOneFetch() async {
        let gate = LibraryPrefetchGate()
        let counter = FetchCounter()
        var fetches: [Task<Void, Never>] = []
        // Rows 75...99 of a 100-row window all appear in one scroll frame; every
        // one of them is inside the prefetch threshold and asks to load.
        for index in 75 ..< 100 {
            guard LibraryPagination.shouldPrefetch(index: index, count: 100) else { continue }
            guard gate.begin() else { continue }
            fetches.append(Task {
                counter.count += 1
                await Task.yield()
                gate.end()
            })
        }
        for fetch in fetches {
            await fetch.value
        }
        #expect(counter.count == 1)
        #expect(gate.begin(), "the gate reopens once the fetch it gated completes")
    }

    @Test("the gate reopens for the next page")
    func gateReopensForTheNextPage() async {
        let gate = LibraryPrefetchGate()
        let counter = FetchCounter()
        for _ in 0 ..< 2 {
            var fetches: [Task<Void, Never>] = []
            for _ in 0 ..< 5 {
                guard gate.begin() else { continue }
                fetches.append(Task {
                    counter.count += 1
                    await Task.yield()
                    gate.end()
                })
            }
            for fetch in fetches {
                await fetch.value
            }
        }
        #expect(counter.count == 2, "one fetch per burst, not one per trigger")
    }

    @Test("a claimed gate reports that it is fetching")
    func claimedGateReportsFetching() {
        let gate = LibraryPrefetchGate()
        #expect(!gate.isFetching)
        #expect(gate.begin())
        #expect(gate.isFetching)
        #expect(!gate.begin())
        gate.end()
        #expect(!gate.isFetching)
    }
}
