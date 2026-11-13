// SidebarFolderTreeSection — the rows inside the sidebar's "Folders" section: the
// folder-filter field, the recursive disclosure tree over the library roots, and the
// flattened match list the filter shows instead.
//
// Lives here rather than in `SidebarView.swift`, which sits close to SwiftLint's
// `file_length` budget; the `Section(isExpanded:)` wrapper and its header stay there.
// Section-level expansion (`NavigationModel.sidebarSectionExpanded`) and per-folder
// expansion (`FolderSidebarViewModel.expandedPaths`) are deliberately SEPARATE axes:
// one collapses the whole section, the other one folder.
import AppKit
import DesignSystem
import Persistence
import SwiftUI
import ViewModels

// MARK: - Section

/// The Folders section's rows. `roots` supplies the depth-0 nodes so a preview can
/// pass fixtures; `model` owns children, expansion and the filter.
struct SidebarFolderTreeSection: View {
    let roots: [FolderSidebarNode]
    let model: FolderSidebarViewModel
    var onRemoveFolder: ((Int64) -> Void)?

    var body: some View {
        SidebarFolderFilterField(model: model)
        let state = FolderTreeRenderState(model: model)
        if state.isFiltering {
            ForEach(state.filteredRows) { node in
                SidebarFolderRow(node: node, onRemoveFolder: onRemoveFolder)
                    .padding(.leading, FolderTreeMetrics.indent(for: node.depth))
            }
        } else {
            ForEach(roots) { root in
                SidebarFolderTreeNode(
                    node: root,
                    state: state,
                    model: model,
                    onRemoveFolder: onRemoveFolder
                )
            }
        }
    }
}

enum FolderTreeMetrics {
    static let indentPerLevel: CGFloat = 12

    static func indent(for depth: Int) -> CGFloat {
        CGFloat(max(depth, 0)) * indentPerLevel
    }
}

// MARK: - Render state

/// An immutable snapshot of the tree, rebuilt from ``FolderSidebarViewModel/visibleNodes``.
///
/// Passing this VALUE down the recursion is what makes the tree re-render: the
/// children cache is `@ObservationIgnored`, so a view reading `children(of:)`
/// directly would never be invalidated when a level finishes loading. `visibleNodes`
/// and `expandedPaths` ARE observed, and both change on every expand/collapse/load,
/// so a node struct that stores this snapshot is re-evaluated exactly when it must be.
struct FolderTreeRenderState: Equatable {
    let childrenByParent: [String: [FolderSidebarNode]]
    let expandedPaths: Set<String>
    let filteredRows: [FolderSidebarNode]
    let isFiltering: Bool

    @MainActor
    init(model: FolderSidebarViewModel) {
        let rows = model.visibleNodes
        isFiltering = !FolderSidebarViewModel.foldedForMatching(model.filterText).isEmpty
        filteredRows = isFiltering ? rows : []
        expandedPaths = model.expandedPaths
        childrenByParent = Dictionary(grouping: rows.filter { $0.depth > 0 }) {
            ($0.path as NSString).deletingLastPathComponent
        }
    }

    func children(of path: String) -> [FolderSidebarNode] {
        childrenByParent[path] ?? []
    }

    /// A materialized child level means the folder is open — which also covers the
    /// ancestors the FILTER opened (its `filterExpandedPaths` set is internal to
    /// PlayerCore). `expandedPaths` then covers the remaining case: a folder the user
    /// opened that turned out to hold no subfolders.
    func isExpanded(_ path: String) -> Bool {
        childrenByParent[path] != nil || expandedPaths.contains(path)
    }
}

// MARK: - Tree node

/// One folder and, while expanded, its subtree. Leaf folders render as a plain row
/// so no chevron is drawn for a level that can never open.
struct SidebarFolderTreeNode: View {
    let node: FolderSidebarNode
    let state: FolderTreeRenderState
    let model: FolderSidebarViewModel
    var onRemoveFolder: ((Int64) -> Void)?

    var body: some View {
        if node.hasChildren {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(state.children(of: node.path)) { child in
                    SidebarFolderTreeNode(
                        node: child,
                        state: state,
                        model: model,
                        onRemoveFolder: onRemoveFolder
                    )
                }
            } label: {
                SidebarFolderRow(node: node, onRemoveFolder: onRemoveFolder)
            }
        } else {
            SidebarFolderRow(node: node, onRemoveFolder: onRemoveFolder)
        }
    }

    private var expansion: Binding<Bool> {
        Binding(
            get: { state.isExpanded(node.path) },
            set: { expanded in
                if expanded {
                    Task { await model.expand(node.path) }
                } else {
                    model.collapse(node.path)
                }
            }
        )
    }
}

// MARK: - Row

/// A single folder row. The Remove / Export context menu is a ROOT-only affordance:
/// a subfolder is not a library root, so neither action has a meaning there.
struct SidebarFolderRow: View {
    let node: FolderSidebarNode
    var onRemoveFolder: ((Int64) -> Void)?

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Label {
            HStack(spacing: tokens.spacing.xSmall) {
                Text(verbatim: node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if node.isMissing {
                    Spacer(minLength: 0)
                    Text(FolderSidebarStrings.missingBadge)
                        .font(tokens.typography.caption.font)
                        .foregroundStyle(tokens.colors.warning.resolve(scheme))
                }
            }
        } icon: {
            Image(systemName: node.destination.systemImage)
        }
        .tag(node.destination)
        .accessibilityIdentifier("sidebar.folder.\(node.rootId)")
        .modifier(FolderRootContextMenu(node: node, isRoot: node.depth == 0, onRemoveFolder: onRemoveFolder))
    }
}

private struct FolderRootContextMenu: ViewModifier {
    let node: FolderSidebarNode
    let isRoot: Bool
    var onRemoveFolder: ((Int64) -> Void)?

    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        if isRoot {
            content.contextMenu {
                Button(MacAMPStrings.sidebarRemoveFolder) {
                    onRemoveFolder?(node.rootId)
                }
                Divider()
                Button(MacAMPStrings.folderExportJSON) {
                    FolderJSONExporter(environment: environment).export(node: node)
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Filter field

/// Filters the folder tree — and NOTHING else. The global `LibrarySearchField`
/// above the sidebar and every other section are untouched by this text.
struct SidebarFolderFilterField: View {
    @Bindable var model: FolderSidebarViewModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: tokens.spacing.xSmall) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
            TextField(String(localized: FolderSidebarStrings.filterPrompt), text: $model.filterText)
                .textFieldStyle(.plain)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .accessibilityIdentifier("sidebar.folderFilter")
                .accessibilityLabel(Text(FolderSidebarStrings.filterAccessibilityLabel))
            if !model.filterText.isEmpty {
                Button { model.filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(Text(MacAMPStrings.searchClear))
                .accessibilityLabel(Text(MacAMPStrings.searchClear))
            }
        }
        .font(tokens.typography.caption.font)
        .padding(.horizontal, tokens.spacing.xSmall)
        .padding(.vertical, tokens.spacing.xxSmall)
        .background(
            RoundedRectangle(cornerRadius: tokens.radii.small, style: .continuous)
                .fill(tokens.colors.surfaceRaised.resolve(scheme))
        )
    }
}

// MARK: - Selection registry

extension FolderSidebarViewModel {
    /// Records the id→path pair behind a folder selection so a relaunch — or a
    /// switch back to this profile — can resolve a SUBFOLDER id, which nothing else
    /// in the registry maps at launch. Both calls are guarded inside the view model,
    /// so firing before the tree has hydrated writes nothing.
    func noteFolderSelection(_ destination: SidebarDestination) {
        if case let .folder(rootId) = destination {
            noteSelection(rootId: rootId)
        } else {
            clearSelection()
        }
    }
}

// MARK: - Export

/// Writes a folder's visible tracks to a JSON file chosen with `NSSavePanel`.
struct FolderJSONExporter {
    let environment: AppEnvironment

    @MainActor
    func export(node: FolderSidebarNode) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(node.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rootPath = node.path
        let repository = TrackRepository(environment.database)
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        Task.detached {
            let tracks = (try? repository.visibleTracksUnderRoot(profileId: profileId, rootPath: rootPath)) ?? []
            let exportItems = tracks.map {
                ExportTrack(
                    title: $0.title,
                    artist: $0.artistName,
                    album: $0.albumTitle,
                    duration: $0.duration ?? 0,
                    filePath: $0.filePath
                )
            }
            if let data = try? JSONEncoder().encode(exportItems) {
                try? data.write(to: url)
            }
        }
    }

    private struct ExportTrack: Encodable {
        let title: String?
        let artist: String?
        let album: String?
        let duration: TimeInterval
        let filePath: String
    }
}
