import Foundation
import Separation

struct KaraokeRenderPreparedWork {
    let url: URL
}

enum KaraokeRenderPreflightOutcome {
    case render(KaraokeRenderPreparedWork)
    case alreadyCached
    case failed
    case cancelled
}

struct KaraokeRenderPreflight {
    let cache: any InstrumentalCaching
    let modelSHA: String

    func makeWork(for url: URL) -> Task<KaraokeRenderPreflightOutcome, Never> {
        Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let identity = try? SeparationCacheKey.sourceIdentity(for: url)
            else { return Task.isCancelled ? .cancelled : .failed }
            let key = SeparationCacheKey(identity: identity, modelSHA: modelSHA)
            if await cache.cachedInstrumental(for: key) != nil {
                guard !Task.isCancelled else { return .cancelled }
                await cache.recordSourceIdentity(for: key, identity: identity)
                return .alreadyCached
            }
            return Task.isCancelled ? .cancelled : .render(KaraokeRenderPreparedWork(url: url))
        }
    }
}
