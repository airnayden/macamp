// probe-glcontext.mm — does this environment grant a COMPLETE default framebuffer
// (FBO 0) via a hidden-window NSOpenGLContext? That is the production path
// (NSOpenGLView) and the only reliable way to capture projectM's FBO-0 composite
// headlessly. Prints FBO-0 completeness + a red-clear readback. Exit 0 = usable.
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl3.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        NSRect frame = NSMakeRect(0, 0, 256, 256);
        NSOpenGLPixelFormatAttribute attrs[] = {
            NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
            NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8,
            NSOpenGLPFADepthSize, 24,
            NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated,
            0
        };
        NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
        if (!pf) { fprintf(stderr, "no pixel format\n"); return 2; }

        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        [win setFrameOrigin:NSMakePoint(-20000, -20000)];
        NSOpenGLView *view = [[NSOpenGLView alloc] initWithFrame:frame pixelFormat:pf];
        [win setContentView:view];
        [win orderBack:nil];

        NSOpenGLContext *ctx = [view openGLContext];
        if (!ctx) { fprintf(stderr, "no GL context\n"); return 2; }
        [ctx makeCurrentContext];
        [ctx update];

        const GLubyte *r = glGetString(GL_RENDERER);
        const GLubyte *v = glGetString(GL_VERSION);
        printf("GL_RENDERER=%s GL_VERSION=%s\n", r ? (const char *)r : "?", v ? (const char *)v : "?");

        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        printf("FBO0 status=0x%04x complete=%d (GL_FRAMEBUFFER_COMPLETE=0x%04x)\n",
               status, status == GL_FRAMEBUFFER_COMPLETE, GL_FRAMEBUFFER_COMPLETE);

        glViewport(0, 0, 256, 256);
        glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glFinish();
        [ctx flushBuffer];

        unsigned char px[4] = {0, 0, 0, 0};
        glReadBuffer(GL_BACK);
        glReadPixels(128, 128, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        GLenum err = glGetError();
        printf("readback center pixel = (%d,%d,%d,%d) GLerr=0x%04x\n", px[0], px[1], px[2], px[3], err);

        bool ok = (status == GL_FRAMEBUFFER_COMPLETE) && (px[0] > 200) && (err == GL_NO_ERROR);
        printf("PROBE-%s\n", ok ? "PASS (FBO0 usable headlessly)" : "FAIL (no usable default framebuffer)");
        return ok ? 0 : 1;
    }
}
