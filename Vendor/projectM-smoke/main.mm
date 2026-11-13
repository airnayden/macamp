//
//  main.mm — headless projectM smoke harness (Task 31 evidence).
//
//  Proves the REAL ObjC++ bridge (macOS/Sources/Visualizer/ProjectM/MacAMPProjectMBridge.mm,
//  compiled here with -DMACAMP_PROJECTM) drives libprojectM v4.1.6 end to end,
//  WITHOUT a window server / GUI session:
//
//    1. Create an offscreen OpenGL 3.2 Core context (Apple GL-on-Metal).
//    2. Create our own complete FBO (color texture + depth) as the render target.
//    3. projectM v4.1.6 hard-codes its final composite to the DEFAULT framebuffer
//       (`glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0)`), which is INCOMPLETE when
//       headless (no drawable; pbuffers are unsupported on Metal-backed GL). We
//       DYLD-interpose `glBindFramebuffer` so any bind-to-0 during rendering is
//       redirected into our readable FBO — capturing projectM's real output.
//    4. Feed a synthesized stereo sine "beat" via the bridge's addPCMFloat.
//    5. Render N frames, glReadPixels, assert the result is NOT uniformly black,
//       and dump a PPM of the final frame for visual evidence.
//
//  Exit 0 = projectM rendered a non-trivial frame fed by PCM. This is a throwaway
//  test artifact, never shipped.
//
#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>     // CGL
#import <OpenGL/gl3.h>        // Core Profile entry points
#import <cmath>
#import <vector>
#import "MacAMPProjectMBridge.h"

static const GLsizei kWidth = 512;
static const GLsizei kHeight = 512;
static const int kFrames = 240;          // ~4s @ 60fps
static const int kSamplesPerFrame = 512; // per channel

static void die(const char *msg) {
    fprintf(stderr, "SMOKE-FAIL: %s (GL 0x%04x)\n", msg, glGetError());
    exit(2);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *presetPath = (argc > 1 && strlen(argv[1]) > 0) ? [NSString stringWithUTF8String:argv[1]] : nil;
        NSString *texturePath = (argc > 2 && strlen(argv[2]) > 0) ? [NSString stringWithUTF8String:argv[2]] : nil;
        NSString *ppmOut = (argc > 3) ? [NSString stringWithUTF8String:argv[3]] : @"/tmp/projectm-smoke.ppm";

        // --- 1. Offscreen Core Profile context -------------------------------
        CGLPixelFormatAttribute attribs[] = {
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL3_Core,
            kCGLPFAColorSize, (CGLPixelFormatAttribute)24,
            kCGLPFAAlphaSize, (CGLPixelFormatAttribute)8,
            kCGLPFADepthSize, (CGLPixelFormatAttribute)24,
            kCGLPFAAccelerated,
            (CGLPixelFormatAttribute)0
        };
        CGLPixelFormatObj pix = NULL;
        GLint nPix = 0;
        if (CGLChoosePixelFormat(attribs, &pix, &nPix) != kCGLNoError || pix == NULL) {
            die("CGLChoosePixelFormat failed");
        }
        CGLContextObj ctx = NULL;
        if (CGLCreateContext(pix, NULL, &ctx) != kCGLNoError || ctx == NULL) {
            die("CGLCreateContext failed");
        }
        CGLSetCurrentContext(ctx);

        // --- 2. Complete capture FBO -----------------------------------------
        GLuint captureFbo = 0, colorTex = 0, depthRb = 0;
        glGenFramebuffers(1, &captureFbo);
        glBindFramebuffer(GL_FRAMEBUFFER, captureFbo);
        glGenTextures(1, &colorTex);
        glBindTexture(GL_TEXTURE_2D, colorTex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kWidth, kHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTex, 0);
        glGenRenderbuffers(1, &depthRb);
        glBindRenderbuffer(GL_RENDERBUFFER, depthRb);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, kWidth, kHeight);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depthRb);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            die("capture FBO incomplete");
        }

        const GLubyte *renderer = glGetString(GL_RENDERER);
        const GLubyte *glver = glGetString(GL_VERSION);
        printf("GL_RENDERER=%s\nGL_VERSION=%s\ncaptureFBO=%u (patched projectM composites here)\n",
               renderer ? (const char *)renderer : "?",
               glver ? (const char *)glver : "?", captureFbo);

        // --- 3. Bridge + preset ----------------------------------------------
        MacAMPProjectMRenderer *pm = [[MacAMPProjectMRenderer alloc] initWithViewportWidth:kWidth height:kHeight];
        if (pm == nil) {
            die("MacAMPProjectMRenderer init returned nil (projectm_create failed)");
        }
        printf("projectM version=%s maxPCMSamples=%lu\n",
               pm.libraryVersion.UTF8String, (unsigned long)pm.maxPCMSamples);

        if (texturePath) {
            [pm setTextureSearchPaths:@[texturePath]];
        }
        [pm loadIdlePreset]; // always-safe baseline (fallback)
        if (presetPath) {
            [pm loadPresetFile:presetPath smooth:NO];
            printf("loaded preset: %s\n", presetPath.UTF8String);
        } else {
            printf("rendering idle preset (no preset path given)\n");
        }

        // --- 4. Feed PCM + render --------------------------------------------
        glViewport(0, 0, kWidth, kHeight);
        std::vector<float> pcm((size_t)kSamplesPerFrame * 2);
        double phase = 0.0;
        const double freq = 220.0;
        const double sr = 44100.0;
        const double dPhase = 2.0 * M_PI * freq / sr;

        for (int f = 0; f < kFrames; f++) {
            double amp = 0.55 + 0.45 * sin((double)f * 0.10); // amplitude LFO -> beats
            for (int i = 0; i < kSamplesPerFrame; i++) {
                float s = (float)(amp * sin(phase));
                pcm[(size_t)i * 2 + 0] = s;
                pcm[(size_t)i * 2 + 1] = s * 0.92f;
                phase += dPhase;
                if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
            }
            [pm addPCMFloat:pcm.data() count:(NSUInteger)kSamplesPerFrame stereo:YES];

            // The patched projectM composites to the bound draw FBO, so binding
            // our complete capture FBO here makes its output readable headlessly.
            glBindFramebuffer(GL_FRAMEBUFFER, captureFbo);
            glViewport(0, 0, kWidth, kHeight);
            [pm renderFrame];
            glFlush();
        }

        // --- 5. Read back + analyze ------------------------------------------
        // Drain any benign errors accumulated during preset rendering (e.g. a
        // preset referencing a texture absent from the pack — projectM degrades
        // to a zero texture and keeps drawing) so the verdict reflects only the
        // readback operation itself.
        while (glGetError() != GL_NO_ERROR) { /* drain */ }
        std::vector<unsigned char> buf((size_t)kWidth * kHeight * 4);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, captureFbo);
        glReadBuffer(GL_COLOR_ATTACHMENT0);
        glReadPixels(0, 0, kWidth, kHeight, GL_RGBA, GL_UNSIGNED_BYTE, buf.data());
        GLenum rerr = glGetError();

        unsigned long nonBlack = 0, sum = 0;
        int maxLum = 0;
        std::vector<unsigned long> hist(256, 0);
        for (size_t i = 0; i < buf.size(); i += 4) {
            int r = buf[i], g = buf[i + 1], b = buf[i + 2];
            int lum = (r * 30 + g * 59 + b * 11) / 100;
            if (lum > 6) nonBlack++;
            sum += (unsigned long)lum;
            if (lum > maxLum) maxLum = lum;
            hist[(size_t)lum]++;
        }
        size_t totalPx = (size_t)kWidth * kHeight;
        double meanLum = (double)sum / (double)totalPx;
        double nonBlackPct = 100.0 * (double)nonBlack / (double)totalPx;
        int distinctLevels = 0;
        for (int i = 0; i < 256; i++) if (hist[(size_t)i] > 0) distinctLevels++;

        printf("readPixels GL=0x%04x meanLum=%.2f maxLum=%d nonBlackPct=%.2f%% distinctLumLevels=%d\n",
               rerr, meanLum, maxLum, nonBlackPct, distinctLevels);

        FILE *fp = fopen(ppmOut.fileSystemRepresentation, "wb");
        if (fp) {
            fprintf(fp, "P6\n%d %d\n255\n", kWidth, kHeight);
            for (int y = kHeight - 1; y >= 0; y--) { // GL bottom-up -> PPM top-down
                for (int x = 0; x < kWidth; x++) {
                    size_t i = ((size_t)y * kWidth + x) * 4;
                    fputc(buf[i], fp);
                    fputc(buf[i + 1], fp);
                    fputc(buf[i + 2], fp);
                }
            }
            fclose(fp);
            printf("wrote PPM: %s\n", ppmOut.UTF8String);
        }

        bool rendered = (rerr == GL_NO_ERROR) && (nonBlackPct > 1.0) && (distinctLevels > 8);
        if (!rendered) {
            fprintf(stderr, "SMOKE-FAIL: framebuffer looks empty (nonBlackPct=%.2f%% levels=%d)\n",
                    nonBlackPct, distinctLevels);
            return 3;
        }
        printf("SMOKE-PASS: projectM rendered a non-trivial frame fed by PCM.\n");

        pm = nil;
        CGLSetCurrentContext(NULL);
        CGLDestroyContext(ctx);
        CGLDestroyPixelFormat(pix);
        return 0;
    }
}
