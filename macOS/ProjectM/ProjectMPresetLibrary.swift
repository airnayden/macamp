//
//  ProjectMPresetLibrary.swift
//  MacAMP — macOS-only projectM (MilkDrop) marquee visualizer backend (Task 31).
//
//  Resolves the projectM preset + texture packs bundled in the app's Resources
//  and vends presets with a graceful idle fallback. NEVER promises every preset
//  renders: the bundled set is a curated allowlist, and a preset that fails to
//  parse/compile leaves projectM on its previous (or idle) visual.
//
#if MACAMP_PROJECTM

import Foundation

struct ProjectMPresetLibrary {
    let presetPaths: [String]
    let textureSearchPaths: [String]

    init(bundle: Bundle = .main) {
        let resources = bundle.resourceURL

        let presetsDir = resources?.appendingPathComponent("presets", isDirectory: true)
        if let presetsDir,
           let urls = try? FileManager.default.contentsOfDirectory(
               at: presetsDir,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            presetPaths = urls
                .filter { $0.pathExtension.lowercased() == "milk" }
                .map(\.path)
                .sorted()
        } else {
            presetPaths = []
        }

        let texturesDir = resources?.appendingPathComponent("textures", isDirectory: true)
        if let texturesDir,
           FileManager.default.fileExists(atPath: texturesDir.path) {
            textureSearchPaths = [texturesDir.path]
        } else {
            textureSearchPaths = []
        }
    }

    var isEmpty: Bool {
        presetPaths.isEmpty
    }

    var count: Int {
        presetPaths.count
    }

    /// The preset path at `index`, wrapping around the curated allowlist. Returns
    /// `nil` when nothing is bundled so the caller falls back to the idle preset.
    func preset(at index: Int) -> String? {
        guard !presetPaths.isEmpty else {
            return nil
        }
        let wrapped = ((index % presetPaths.count) + presetPaths.count) % presetPaths.count
        return presetPaths[wrapped]
    }
}

#endif
