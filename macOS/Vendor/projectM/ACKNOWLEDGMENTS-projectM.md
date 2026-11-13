# projectM (MilkDrop) Visualizer — Third-Party Acknowledgments

The macOS-only "projectM" visualizer backend (built into the `macampMac` target,
never iOS) bundles and dynamically links the following third-party components.

## libprojectM 4.1.6 — LGPL v2.1

- **Project**: projectM — https://github.com/projectM-visualizer/projectm
- **Version**: v4.1.6 (git tag)
- **License**: GNU Lesser General Public License, version 2.1
  (full text: `LICENSE-projectM-LGPL-2.1.txt` in this directory).
- **Linkage**: **dynamic** only (`libprojectM-4.4.dylib`, embedded in
  `MacAMP.app/Contents/Frameworks`, loaded via `@rpath`). The LGPL permits use
  in a closed-source application **as a shared library** as long as the library
  itself (and any modifications to it) remain under the LGPL and the user can
  relink against a modified library. We satisfy this by (a) linking dynamically,
  (b) shipping the unmodified-plus-documented-patch source build recipe, and
  (c) keeping our modification under the LGPL (see below).
- **Why macOS-only / non-App-Store**: libprojectM is OpenGL-only (its CMake build
  fatal-errors on iOS/GLES) and LGPL. Static-only App Store distribution cannot
  honor the LGPL relink clause, so this backend ships ONLY via direct macOS
  distribution (DMG). This is the project-wide "Strategy A" decision.

### Our modification (LGPL §2 notice)

One file is patched: `src/libprojectM/ProjectM.cpp`,
`ProjectM::RenderFrame()`. The hardcoded final-composite target
`glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0)` is changed to composite to the
framebuffer the **host** bound on entry (captured via
`GL_DRAW_FRAMEBUFFER_BINDING`). This is a backport of projectM v4.2's
host-provided-target-framebuffer behavior (the upstream code carries the exact
`ToDo` for it). It is behavior-identical to upstream when the host binds `0`
(e.g. an `NSOpenGLView` drawable), and additionally enables offscreen/headless
rendering. The patch is kept under the LGPL and committed at:
`Vendor/projectM-patches/0001-macamp-host-target-framebuffer.patch`.

### Reproducing the build

```
./Vendor/build-projectm.sh
```

Clones v4.1.6 (shallow + submodules), applies `Vendor/projectM-patches/*.patch`,
and CMake-builds a shared `libprojectM-4.dylib` for macOS arm64 (deployment
14.0). The resulting dylib + headers are staged under `macOS/Vendor/projectM/`.

## Preset pack — "Cream of the Crop"

- **Source**: https://github.com/projectM-visualizer/presets-cream-of-the-crop
- **License**: see `LICENSE-presets-cream-of-the-crop.md` in this directory.
- A **curated allowlist subset** (~40 presets) is bundled under `presets/`. The
  full ~9,795-preset pack is NOT bundled. MacAMP does **not** promise every
  preset renders — a preset that fails to parse/compile gracefully leaves
  projectM on its previous (or idle) visual.

## Texture pack — "Milkdrop Texture Pack"

- **Source**: https://github.com/projectM-visualizer/presets-milkdrop-texture-pack
- Bundled under `textures/` (see `README-texture-pack.md`). Referenced by presets
  via `projectm_set_texture_search_paths`.

## OpenGL

- The backend uses Apple's system **OpenGL.framework** (Core Profile 3.2; macOS
  caps OpenGL at 4.1). OpenGL is deprecated on macOS but remains functional;
  this is consistent with projectM being OpenGL-only.
