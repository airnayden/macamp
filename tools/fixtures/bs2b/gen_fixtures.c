/*
 * Emits the reference impulse response of libbs2b 3.1.0 for MacAMP's three
 * shipped crossfeed presets, as CSV, at 44.1 kHz.
 *
 * This is the INDEPENDENT ORACLE for `CrossfeedKernel`: it links the upstream
 * `bs2b.c` verbatim and never sees a line of MacAMP's own math. Run once via
 * `build.sh`; the produced CSVs are committed and the Swift tests read only
 * those. See README.md for provenance.
 *
 * Input is L-only (L = 1.0, R = 0.0 on frame 0, silence afterwards); both
 * output channels are recorded, because a bs2b crossfeed puts the highboosted
 * direct path on L and the lowpassed crossfeed path on R.
 */

#include <stdio.h>
#include <stdlib.h>

#include "bs2b.h"

#define FRAME_COUNT 256

struct preset {
    const char *name;
    uint32_t clevel;
};

static int emit(const struct preset *preset)
{
    char path[512];
    t_bs2bdp bs2bdp = bs2b_open();
    if (bs2bdp == NULL) {
        fprintf(stderr, "bs2b_open failed\n");
        return 1;
    }
    bs2b_set_srate(bs2bdp, 44100);
    bs2b_set_level(bs2bdp, preset->clevel);
    bs2b_clear(bs2bdp);

    snprintf(path, sizeof(path), "vectors/%s-44100.csv", preset->name);
    FILE *out = fopen(path, "w");
    if (out == NULL) {
        fprintf(stderr, "cannot write %s\n", path);
        bs2b_close(bs2bdp);
        return 1;
    }

    fprintf(out, "# libbs2b 3.1.0 impulse response, L-only input (L=1.0 R=0.0 at n=0)\n");
    fprintf(out, "# preset=%s fcut=%d Hz feed=%d (tenths of dB) srate=44100\n",
            preset->name, bs2b_get_level_fcut(bs2bdp), bs2b_get_level_feed(bs2bdp));
    fprintf(out, "n,out_l,out_r\n");

    for (int frame = 0; frame < FRAME_COUNT; frame++) {
        double sample[2];
        sample[0] = (frame == 0) ? 1.0 : 0.0;
        sample[1] = 0.0;
        bs2b_cross_feed_d(bs2bdp, sample, 1);
        /* bs2b_cross_feed_d clips at +/-1.0; a unit impulse never reaches it,
         * so the recorded response is the unclipped kernel output. Assert it. */
        if (sample[0] >= 1.0 || sample[0] <= -1.0 || sample[1] >= 1.0 || sample[1] <= -1.0) {
            fprintf(stderr, "%s: clipping engaged at n=%d — fixture invalid\n", preset->name, frame);
            fclose(out);
            bs2b_close(bs2bdp);
            return 1;
        }
        fprintf(out, "%d,%.17g,%.17g\n", frame, sample[0], sample[1]);
    }

    fclose(out);
    bs2b_close(bs2bdp);
    printf("wrote %s\n", path);
    return 0;
}

int main(void)
{
    const struct preset presets[] = {
        { "default", BS2B_DEFAULT_CLEVEL },
        { "cmoy", BS2B_CMOY_CLEVEL },
        { "jmeier", BS2B_JMEIER_CLEVEL },
    };

    for (size_t index = 0; index < sizeof(presets) / sizeof(presets[0]); index++) {
        if (emit(&presets[index]) != 0) {
            return 1;
        }
    }
    return 0;
}
