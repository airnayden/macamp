//
//  MacAMPProjectMBridge.mm
//  MacAMP — macOS-only projectM (MilkDrop) marquee visualizer backend (Task 31).
//
//  The ENTIRE projectM-touching body is gated behind `#if MACAMP_PROJECTM`. In
//  App Store / default builds the macro is undefined, so this translation unit
//  compiles to an empty Objective-C class with no projectM/OpenGL symbols — the
//  binary is App-Store-safe (verified via `nm -gU`). The DMG-only projectM build
//  target defines MACAMP_PROJECTM and links libprojectM-4.dylib.
//
//  LGPL v2.1: libprojectM is dynamically linked. Bundled source reference:
//  Vendor/projectM/src (cloned at tag v4.1.6); license text:
//  macOS/Vendor/projectM/LICENSE-projectM-LGPL-2.1.txt.
//

#import "MacAMPProjectMBridge.h"

#if MACAMP_PROJECTM

#import <projectM-4/projectM.h>

@implementation MacAMPProjectMRenderer {
    projectm_handle _handle;
}

- (nullable instancetype)initWithViewportWidth:(NSUInteger)width height:(NSUInteger)height {
    self = [super init];
    if (!self) {
        return nil;
    }

    // projectm_create() needs a CURRENT OpenGL context on this thread. If the
    // host failed to make one current, this returns NULL and we hand back nil so
    // the Swift host can fall back to the Metal backend.
    _handle = projectm_create();
    if (_handle == NULL) {
        return nil;
    }

    const size_t w = (size_t)MAX((NSUInteger)16, width);
    const size_t h = (size_t)MAX((NSUInteger)16, height);
    projectm_set_window_size(_handle, w, h);

    // Conservative, smooth defaults. Mesh clamped internally to [8,300]; 48x32 is
    // a good macOS-retina default. Presets auto-advance every 30s with a 3s blend.
    projectm_set_mesh_size(_handle, 48, 32);
    projectm_set_fps(_handle, 60);
    projectm_set_aspect_correction(_handle, true);
    projectm_set_preset_duration(_handle, 30.0);
    projectm_set_soft_cut_duration(_handle, 3.0);
    projectm_set_hard_cut_enabled(_handle, false);

    return self;
}

- (void)dealloc {
    if (_handle != NULL) {
        projectm_destroy(_handle);
        _handle = NULL;
    }
}

- (void)setTextureSearchPaths:(NSArray<NSString *> *)paths {
    if (_handle == NULL || paths.count == 0) {
        return;
    }

    const size_t count = (size_t)paths.count;
    // Build a C array of UTF-8 path pointers backed by the autoreleased NSData of
    // each string; the C call copies them synchronously so this lifetime is safe.
    const char **cPaths = (const char **)malloc(sizeof(char *) * count);
    if (cPaths == NULL) {
        return;
    }
    for (size_t i = 0; i < count; i++) {
        cPaths[i] = [paths[i] fileSystemRepresentation];
    }
    projectm_set_texture_search_paths(_handle, cPaths, count);
    free(cPaths);
}

- (void)loadPresetFile:(NSString *)path smooth:(BOOL)smooth {
    if (_handle == NULL) {
        return;
    }
    // projectM keeps the current preset if this file fails to parse/compile —
    // that is the graceful per-preset fallback the contract requires.
    projectm_load_preset_file(_handle, [path fileSystemRepresentation], smooth ? true : false);
}

- (void)loadIdlePreset {
    if (_handle == NULL) {
        return;
    }
    projectm_load_preset_file(_handle, "idle://", false);
}

- (void)addPCMFloat:(const float *)samples count:(NSUInteger)count stereo:(BOOL)stereo {
    if (_handle == NULL || samples == NULL || count == 0) {
        return;
    }
    projectm_pcm_add_float(_handle,
                           samples,
                           (unsigned int)count,
                           stereo ? PROJECTM_STEREO : PROJECTM_MONO);
}

- (void)renderFrame {
    if (_handle == NULL) {
        return;
    }
    projectm_opengl_render_frame(_handle);
}

- (void)setViewportWidth:(NSUInteger)width height:(NSUInteger)height {
    if (_handle == NULL) {
        return;
    }
    projectm_set_window_size(_handle, (size_t)MAX((NSUInteger)16, width), (size_t)MAX((NSUInteger)16, height));
}

- (NSUInteger)maxPCMSamples {
    return (NSUInteger)projectm_pcm_get_max_samples();
}

- (NSString *)libraryVersion {
    char *version = projectm_get_version_string();
    if (version == NULL) {
        return @"unknown";
    }
    NSString *result = [NSString stringWithUTF8String:version];
    projectm_free_string(version);
    return result ?: @"unknown";
}

@end

#else  // !MACAMP_PROJECTM — App-Store-safe stub: zero projectM symbols.

@implementation MacAMPProjectMRenderer

- (nullable instancetype)initWithViewportWidth:(NSUInteger)width height:(NSUInteger)height {
    // projectM is not compiled into this build. Return nil so the host falls
    // back to the cross-platform Metal backend.
    (void)width;
    (void)height;
    return nil;
}

- (void)setTextureSearchPaths:(NSArray<NSString *> *)paths {
    (void)paths;
}
- (void)loadPresetFile:(NSString *)path smooth:(BOOL)smooth {
    (void)path;
    (void)smooth;
}
- (void)loadIdlePreset {
}
- (void)addPCMFloat:(const float *)samples count:(NSUInteger)count stereo:(BOOL)stereo {
    (void)samples;
    (void)count;
    (void)stereo;
}
- (void)renderFrame {
}
- (void)setViewportWidth:(NSUInteger)width height:(NSUInteger)height {
    (void)width;
    (void)height;
}
- (NSUInteger)maxPCMSamples {
    return 0;
}
- (NSString *)libraryVersion {
    return @"disabled";
}

@end

#endif // MACAMP_PROJECTM
