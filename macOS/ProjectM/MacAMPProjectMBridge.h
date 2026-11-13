//
//  MacAMPProjectMBridge.h
//  MacAMP — macOS-only projectM (MilkDrop) marquee visualizer backend (Task 31).
//
//  A thin, clean Objective-C facade over the libprojectM v4 C API. It exposes ONLY
//  Foundation types so Swift (and the headless smoke harness) never see a single
//  projectM/OpenGL symbol — those stay inside the .mm translation unit.
//
//  THREADING CONTRACT (load-bearing): libprojectM requires that the instance be
//  created AND rendered on the SAME thread, and that an OpenGL context is CURRENT
//  on that thread for both `projectm_create()` and every `renderFrame`. This
//  facade does NOT own a GL context — the host (an NSOpenGLView / CAOpenGLLayer
//  on the app side, a CGL pbuffer on the smoke-harness side) makes its context
//  current before calling in. All calls on one instance MUST happen on that one
//  GL thread; the facade is NOT thread-safe by design (matching the C library).
//
//  LICENSE: libprojectM is LGPL v2.1 (see Vendor/projectM/LICENSE-projectM-LGPL-2.1.txt).
//  This backend is dynamically linked and compiled OUT of App Store builds.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C facade over a single libprojectM v4 instance.
///
/// Create on the GL thread (with a current context), feed PCM via
/// ``addPCMFloat:count:stereo:``, then call ``renderFrame`` once per display
/// tick. The current OpenGL framebuffer receives the rendered frame.
__attribute__((objc_subclassing_restricted))
@interface MacAMPProjectMRenderer : NSObject

/// Creates a projectM instance for a viewport of `width` x `height` pixels.
///
/// REQUIRES a current OpenGL context (Core Profile 3.x) on the calling thread.
/// Returns `nil` if `projectm_create()` fails (no/insufficient GL context) so the
/// host can gracefully fall back to the Metal backend.
- (nullable instancetype)initWithViewportWidth:(NSUInteger)width
                                        height:(NSUInteger)height NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Texture search paths used to resolve preset texture references. Call BEFORE
/// loading presets that reference textures. Resets and reloads textures.
- (void)setTextureSearchPaths:(NSArray<NSString *> *)paths;

/// Loads a Milkdrop `.milk` preset from `path`. If `smooth` is YES the new preset
/// is blended in. On failure projectM keeps the currently displayed preset
/// (graceful fallback) — see ``loadIdlePreset`` for an explicit safe baseline.
- (void)loadPresetFile:(NSString *)path smooth:(BOOL)smooth;

/// Loads the built-in idle preset (the "M" logo) — the always-available fallback
/// used when a preset pack is missing or a preset fails to render.
- (void)loadIdlePreset;

/// Feeds 32-bit float PCM. When `stereo` is YES, `samples` is interleaved LRLR…
/// and `count` is the number of frames PER channel. Each sample should be in
/// [-1, 1]. Safe to call every audio buffer; projectM stores up to
/// ``maxPCMSamples`` per channel and discards the rest.
- (void)addPCMFloat:(const float *)samples count:(NSUInteger)count stereo:(BOOL)stereo;

/// Renders exactly one frame into the currently bound OpenGL framebuffer.
- (void)renderFrame;

/// Updates the viewport size in pixels (resets the GL renderer). Call on resize.
- (void)setViewportWidth:(NSUInteger)width height:(NSUInteger)height;

/// Maximum PCM samples per channel projectM stores per ``addPCMFloat:count:stereo:``.
@property (nonatomic, readonly) NSUInteger maxPCMSamples;

/// The linked libprojectM runtime version, e.g. "4.1.6".
@property (nonatomic, readonly, copy) NSString *libraryVersion;

@end

NS_ASSUME_NONNULL_END
