// FolderSidebarViewModel+Tree — the lazy subfolder tree: child loading, expansion,
// the flattened render list, and the bounded folder filter.
//
// Split out of `FolderSidebarViewModel.swift` to stay inside SwiftLint's file and
// type budgets, mirroring the `PlaybackCoordinator+*.swift` precedent. Everything
// here derives from `TrackRepository.childFolders` — no filesystem walk, no AppKit.
import Foundation
import Persistence

// MARK: - Child levels

public extension FolderSidebarViewModel {
    /// The cached children of `path`, or `nil` when that level has not loaded yet.
    func children(of path: String) -> [FolderSidebarNode]? {
        childrenCache[path]
    }

    /// Whether `path` renders expanded — the user's own expansion, or an ancestor
    /// the active filter had to open to reveal a match.
    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path) || filterExpandedPaths.contains(path)
    }

    /// Loads and caches one level of subfolders beneath `path`, off the main actor.
    ///
    /// Cached levels are returned without a second query, and concurrent callers
    /// share one in-flight load — so expanding a folder issues exactly one
    /// ``FolderTreeReading/childFolders(profileId:parentPath:)`` call per refresh
    /// generation, and collapsing then re-expanding issues none. A path no visible
    /// track lives under (a folder that vanished between refreshes) yields `[]`
    /// rather than throwing.
    @discardableResult
    func loadChildren(of path: String) async -> [FolderSidebarNode] {
        if let cached = childrenCache[path] {
            return cached
        }
        if let inFlight = childLoads[path] {
            return await inFlight.value
        }
        let task = Task { [weak self] () -> [FolderSidebarNode] in
            guard let self else { return [] }
            return await performChildLoad(path)
        }
        childLoads[path] = task
        let loaded = await task.value
        if childLoads[path] == task {
            childLoads[path] = nil
        }
        return loaded
    }

    /// Expands `path`, loading its child level if needed, and persists the change.
    func expand(_ path: String) async {
        guard !expandedPaths.contains(path) else { return }
        expandedPaths.insert(path)
        persist()
        await loadChildren(of: path)
        rebuildVisibleNodes()
    }

    /// Collapses `path` and persists the change. The loaded child level stays cached,
    /// so re-expanding it costs no query.
    func collapse(_ path: String) {
        guard expandedPaths.remove(path) != nil else { return }
        persist()
        rebuildVisibleNodes()
    }

    /// Flips `path` between expanded and collapsed.
    func toggle(_ path: String) async {
        if expandedPaths.contains(path) {
            collapse(path)
        } else {
            await expand(path)
        }
    }
}

// MARK: - Filter

public extension FolderSidebarViewModel {
    /// How many levels below the roots the filter's breadth-first walk descends.
    /// Bounds the work on a pathologically deep tree; roots themselves are depth 0.
    static var filterMaxDepth: Int {
        6
    }

    /// How many folders the filter's breadth-first walk may visit. Bounds both the
    /// query count and the working set on a pathologically wide tree.
    static var filterMaxNodes: Int {
        500
    }

    /// Sets ``filterText`` and awaits the re-derivation — the deterministic spelling
    /// for callers that need ``visibleNodes`` settled before continuing.
    func setFilter(_ text: String) async {
        filterText = text
        cancelPendingFilter()
        await applyFilter()
    }

    /// Re-derives ``visibleNodes`` for the current ``filterText``.
    ///
    /// An empty query restores the ordinary lazy tree. A non-empty one walks the tree
    /// breadth-first within the depth/node caps, matching folder names
    /// case- and diacritic-insensitively, and publishes the matches flattened with
    /// every ancestor needed to reach them marked expanded.
    func applyFilter() async {
        let needle = Self.foldedForMatching(filterText)
        guard !needle.isEmpty else {
            filterMatchPaths = nil
            filterExpandedPaths = []
            rebuildVisibleNodes()
            return
        }
        let startGeneration = generation
        let matches = await searchTree(matching: needle)
        guard startGeneration == generation else { return }
        filterMatchPaths = matches
        filterExpandedPaths = Set(matches.flatMap {
            Self.ancestorChain(of: $0, roots: nodes.map(\.path))
        })
        rebuildVisibleNodes()
    }

    /// Folds a name or query to the form both sides of a filter match compare in:
    /// case-, diacritic- and width-insensitive, with surrounding whitespace removed.
    static func foldedForMatching(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

// MARK: - Render list

extension FolderSidebarViewModel {
    /// Rebuilds ``visibleNodes`` — the flattened rows the sidebar renders.
    func rebuildVisibleNodes() {
        if filterMatchPaths != nil {
            rebuildFilteredNodes()
            return
        }
        var rows: [FolderSidebarNode] = []
        for root in nodes {
            rows.append(root)
            appendSubtree(of: root, keeping: nil, into: &rows)
        }
        visibleNodes = rows
    }

    private func rebuildFilteredNodes() {
        guard let matches = filterMatchPaths else { return }
        let keep = matches.union(filterExpandedPaths)
        var rows: [FolderSidebarNode] = []
        for root in nodes where keep.contains(root.path) {
            rows.append(root)
            appendSubtree(of: root, keeping: keep, into: &rows)
        }
        visibleNodes = rows
    }

    /// Appends the materialized subtree beneath `node`. `keep` restricts the walk to
    /// the filter's match-and-ancestor set; `nil` means the ordinary expansion walk.
    private func appendSubtree(
        of node: FolderSidebarNode,
        keeping keep: Set<String>?,
        into rows: inout [FolderSidebarNode]
    ) {
        if keep == nil, !isExpanded(node.path) {
            return
        }
        guard let children = childrenCache[node.path] else { return }
        for child in children where keep?.contains(child.path) ?? true {
            rows.append(child)
            appendSubtree(of: child, keeping: keep, into: &rows)
        }
    }
}

// MARK: - Internals

private extension FolderSidebarViewModel {
    /// Runs the actual child query and folds the result into the cache + registry.
    /// A result that arrives after a refresh bumped the generation is discarded.
    func performChildLoad(_ path: String) async -> [FolderSidebarNode] {
        let startGeneration = generation
        let summaries = await fetchChildren(parentPath: path)
        guard startGeneration == generation else { return childrenCache[path] ?? [] }
        let parent = nodesByPath[path]
        let built = sorted(summaries.map { summary in
            FolderSidebarNode(
                rootId: Self.stableRootId(forPath: summary.path),
                path: summary.path,
                name: summary.name,
                // Availability is a whole-root property (the tally that badges a root
                // covers every track beneath it), so a child inherits its parent's
                // state instead of paying one aggregate query per folder.
                isMissing: parent?.isMissing ?? false,
                hasChildren: summary.hasChildren,
                depth: (parent?.depth ?? 0) + 1,
                newestDateAdded: summary.newestDateAdded
            )
        })
        childrenCache[path] = built
        knownHasChildren[path] = !built.isEmpty
        for child in built {
            register(child)
        }
        return built
    }

    func fetchChildren(parentPath: String) async -> [FolderChildSummary] {
        let repository = repository
        let profileId = activeProfileId
        return await Task.detached {
            (try? repository.childFolders(profileId: profileId, parentPath: parentPath)) ?? []
        }.value
    }

    /// The bounded breadth-first walk behind ``applyFilter()``.
    func searchTree(matching needle: String) async -> Set<String> {
        var matches: Set<String> = []
        var frontier = nodes
        var visited = 0
        var depth = 0
        while !frontier.isEmpty, depth < Self.filterMaxDepth, visited < Self.filterMaxNodes {
            var next: [FolderSidebarNode] = []
            for node in frontier {
                visited += 1
                if visited > Self.filterMaxNodes { break }
                if Self.foldedForMatching(node.name).contains(needle) {
                    matches.insert(node.path)
                }
                guard node.hasChildren, next.count < Self.filterMaxNodes else { continue }
                let children = await loadChildren(of: node.path)
                next.append(contentsOf: children.prefix(Self.filterMaxNodes - next.count))
            }
            frontier = next
            depth += 1
        }
        return matches
    }
}
