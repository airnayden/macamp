// FolderOutlineView — the main window's hierarchical folder browser.
//
// A `.folder` destination used to render one flat, RECURSIVE track list. It now
// renders an outline: the browsed directory's immediate subfolders first (each with
// its recursive track count), then that directory's own direct files. A subfolder's
// chevron expands it INLINE, indented, to any depth; a double-click on the row
// navigates the sidebar selection into it instead.
//
// Written as a ``LibraryBrowserView`` extension — the `LibraryBrowserSearch.swift` /
// `LibraryBrowserPagination.swift` precedent — so the outline reuses the browser's
// existing context menu, playback and favourite actions verbatim, and so
// `LibraryBrowserView.swift` stays inside SwiftLint's type-body budget. `folderList`
// moved here from that file for the same reason.
import DesignSystem
import Persistence
import Services
import SwiftUI
import ViewModels

/// The `.task(id:)` key that rebuilds the outline: a different folder, a profile
/// switch, or a completed import all invalidate every loaded level.
struct FolderOutlineKey: Hashable {
    let rootPath: String
    let profileId: Int64
    let revision: Int
}

// MARK: - Routing

extension LibraryBrowserView {
    /// The browser's list.
    ///
    /// The outline owns `.folder` destinations; the flat keyset list keeps every
    /// other mode — All Tracks, a genre window, and a live in-view search, whose
    /// ranked results span the whole subtree and so belong to no single level.
    @ViewBuilder
    var browseContent: some View {
        if let filterRootPath, !localSearch.isActive {
            folderOutline(rootPath: filterRootPath)
        } else {
            folderList
        }
    }

    var folderList: some View {
        List(selection: $selection) {
            ForEach(derivedRows) { row in
                TrackListRow(
                    number: row.trackNumber,
                    title: row.titleText,
                    artist: row.artistText,
                    artistId: row.track.artistId,
                    duration: row.track.duration,
                    isPlaying: isCurrent(row.track),
                    availability: row.track.availability,
                    isFavourite: isFavourite(row.track),
                    onToggleFavourite: { toggleFavourite(row.track) },
                    karaokeState: environment.karaokeRowState(
                        filePath: row.track.filePath,
                        enabled: settings.karaokeEnabled
                    ),
                    onRequestKaraokeRender: environment.karaokeRenderAction(
                        filePath: row.track.filePath,
                        enabled: settings.karaokeEnabled
                    ),
                    onDequeueKaraoke: environment.karaokeDequeueAction(
                        filePath: row.track.filePath,
                        enabled: settings.karaokeEnabled
                    )
                )
                .tag(row.id)
                .moveDisabled(!localFilter.isEmpty || !canReorderOutline)
                .onAppear { loadMoreIfNeeded(row) }
            }
            .onMove(perform: moveFolderTracks)
        }
        .scrollContentBackground(.hidden)
        .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
        .contextMenu(forSelectionType: Int64.self) { ids in
            menuItems(for: ids)
        } primaryAction: { ids in
            play(ids)
        }
    }

    func folderOutline(rootPath: String) -> some View {
        outlineList
            .task(id: outlineKey(rootPath)) { await configureOutline(rootPath: rootPath) }
            .onChange(of: selectedGenre) { _, genre in outline?.genreFilter = genre }
            .onChange(of: settings.folderSort.browser) { _, sort in outline?.filesSort = sort }
    }
}

// MARK: - Outline list

private extension LibraryBrowserView {
    /// Two `ForEach`es, not one: the browsed root's own files are always the
    /// contiguous trailing block of the outline, so putting them in their own loop is
    /// what lets `.onMove` cover the root level and nothing else — no index
    /// translation, and a nested level is structurally unreorderable.
    ///
    /// Subfolder rows carry no `.tag`, so they are not selection items and the
    /// collection context menu never builds anything for them.
    @ViewBuilder
    var outlineList: some View {
        if let outline {
            List(selection: $selection) {
                ForEach(outline.subtreeRows) { row in
                    outlineRow(row, outline: outline)
                }
                ForEach(outline.rootFileRows) { file in
                    outlineFileRow(file, outline: outline)
                        .moveDisabled(!canReorderOutlineRoot)
                }
                .onMove(perform: moveOutlineRootFiles)
            }
            .scrollContentBackground(.hidden)
            .background(tokens.colors.canvas.resolve(scheme).opacity(0.25))
            .contextMenu(forSelectionType: Int64.self) { ids in
                if !ids.isEmpty {
                    menuItems(for: ids)
                }
            } primaryAction: { ids in
                playOutline(ids, outline: outline)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    func outlineRow(_ row: FolderOutlineRow, outline: FolderOutlineViewModel) -> some View {
        switch row {
        case let .folder(folder):
            FolderOutlineFolderRow(
                folder: folder,
                onToggle: { Task { await outline.toggle(folder.path) } },
                onOpen: { openFolder(folder.path) }
            )
            .padding(.leading, FolderTreeMetrics.indent(for: folder.depth))
        case let .file(file):
            outlineFileRow(file, outline: outline)
        }
    }

    func outlineFileRow(_ file: FolderOutlineFile, outline: FolderOutlineViewModel) -> some View {
        let row = LibraryTrackRow(track: file.track)
        return TrackListRow(
            number: row.trackNumber,
            title: row.titleText,
            artist: row.artistText,
            artistId: row.track.artistId,
            duration: row.track.duration,
            isPlaying: isCurrent(row.track),
            availability: row.track.availability,
            isFavourite: isFavourite(row.track),
            onToggleFavourite: { toggleFavourite(row.track) },
            karaokeState: environment.karaokeRowState(
                filePath: row.track.filePath,
                enabled: settings.karaokeEnabled
            ),
            onRequestKaraokeRender: environment.karaokeRenderAction(
                filePath: row.track.filePath,
                enabled: settings.karaokeEnabled
            ),
            onDequeueKaraoke: environment.karaokeDequeueAction(
                filePath: row.track.filePath,
                enabled: settings.karaokeEnabled
            )
        )
        .padding(.leading, FolderTreeMetrics.indent(for: file.depth))
        .tag(file.trackId)
        .onAppear { Task { await outline.prefetchFilesIfNeeded(file) } }
    }
}

// MARK: - Outline actions

private extension LibraryBrowserView {
    /// Today's ``FolderReorderPolicy`` rule plus the search clause: a live in-view
    /// query replaces the rows wholesale, so a drag would persist positions that
    /// describe no folder's real order.
    var canReorderOutlineRoot: Bool {
        canReorderOutline && localFilter.isEmpty
    }

    func outlineKey(_ rootPath: String) -> FolderOutlineKey {
        FolderOutlineKey(
            rootPath: rootPath,
            profileId: activeProfileId,
            revision: environment.libraryFolders.revision
        )
    }

    func configureOutline(rootPath: String) async {
        let model = FolderOutlineViewModel(
            repository: TrackRepository(environment.database),
            rootPath: rootPath,
            activeProfileId: activeProfileId,
            filesSort: settings.folderSort.browser
        )
        model.genreFilter = selectedGenre
        outline = model
        await model.load()
    }

    /// Queues the visible files of the clicked row's OWN level, so a double-click in
    /// a nested folder plays that folder rather than the whole subtree.
    func playOutline(_ ids: Set<Int64>, outline: FolderOutlineViewModel) {
        guard let clickedId = ids.first,
              let levelPath = outline.levelPath(forTrack: clickedId)
        else { return }
        let refs = outline.visibleFiles(in: levelPath).map { TrackRef(record: $0) }
        guard !refs.isEmpty else { return }
        let startIndex = refs.firstIndex(where: { $0.trackID == clickedId }) ?? 0
        environment.coordinator.setQueue(refs, startingAt: startIndex, source: playbackSource)
        environment.queue.refresh()
    }

    func moveOutlineRootFiles(from source: IndexSet, to destination: Int) {
        guard let outline,
              let reordered = outline.moveRootFiles(
                  from: source,
                  to: destination,
                  isEnabled: canReorderOutlineRoot
              )
        else { return }
        environment.coordinator.reorderQueue(reordered.map { TrackRef(record: $0) })
        environment.queue.refresh()
    }

    /// Navigates the sidebar selection into `path`.
    ///
    /// `MainWindowContent.folderPath(for:)` resolves a `.folder(rootId:)` through
    /// `FolderSidebarViewModel.path(forId:)`, which maps only the nodes the SIDEBAR
    /// tree has MATERIALIZED — a synthesized id for a folder the sidebar never
    /// expanded resolves to `nil` and would silently fall back to All Tracks.
    /// Expanding the ancestor chain first registers the node (and reveals it in the
    /// tree), so the id resolves by the time the selection changes.
    func openFolder(_ path: String) {
        guard let filterRootPath else { return }
        let sidebar = environment.libraryFolders.sidebar
        let chain = Self.ancestorChain(from: filterRootPath, to: path)
        Task {
            for ancestor in chain {
                await sidebar.expand(ancestor)
                await sidebar.loadChildren(of: ancestor)
            }
            nav.sidebar = .folder(rootId: FolderSidebarViewModel.stableRootId(forPath: path))
        }
    }

    /// Every directory from `root` down to `path`'s parent, top-down.
    static func ancestorChain(from root: String, to path: String) -> [String] {
        var chain: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while current.count >= root.count, current.hasPrefix(root) {
            chain.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return chain.reversed()
    }
}

// MARK: - Folder row

/// One subfolder row: a disclosure chevron, a folder glyph, the name, and the
/// RECURSIVE track count beneath it.
///
/// The chevron is unconditional, unlike the sidebar tree's: the sidebar shows only
/// folders, so a folder with no subfolder can never open, while the outline also
/// shows FILES — and every folder `childFolders` reports holds at least one.
///
/// Deliberately NO context menu: Remove / Export JSON are library-root affordances
/// that the sidebar owns, and a subfolder is not a root.
private struct FolderOutlineFolderRow: View {
    let folder: FolderOutlineFolder
    let onToggle: () -> Void
    let onOpen: () -> Void

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.small) {
            chevron
            Image(systemName: "folder")
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
            Text(verbatim: folder.name)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: tokens.spacing.small)
            Text(verbatim: LibraryGridStrings.trackCount(folder.trackCount))
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .padding(.vertical, tokens.spacing.xxSmall)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .pointingHandCursor()
        .help(Text(FolderOutlineStrings.openFolder))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: folder.name))
        .accessibilityIdentifier("library.folder.\(FolderSidebarViewModel.stableRootId(forPath: folder.path))")
    }

    private var disclosureLabel: LocalizedStringResource {
        folder.isExpanded ? FolderOutlineStrings.collapseFolder : FolderOutlineStrings.expandFolder
    }

    private var chevron: some View {
        Button(action: onToggle) {
            Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(Text(disclosureLabel))
        .accessibilityLabel(Text(disclosureLabel))
    }
}
