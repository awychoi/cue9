#ifndef CUE9_PREVIEW_H
#define CUE9_PREVIEW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cue9_preview cue9_preview;
typedef struct cue9_rgb {
    uint8_t r, g, b;
} cue9_rgb;

cue9_preview *cue9_preview_create(uint32_t seed);
void cue9_preview_destroy(cue9_preview *preview);
void cue9_preview_reset(cue9_preview *preview);
int cue9_preview_render(cue9_preview *preview, int state, float t, float dt,
                        const cue9_rgb *color, const cue9_rgb *background,
                        uint16_t *out, int out_len);

#ifdef __cplusplus
}
#endif

#endif
