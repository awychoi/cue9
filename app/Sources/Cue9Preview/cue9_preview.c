#include "cue9_preview.h"

#include <stdlib.h>
#include <string.h>

#include "pip_scene.h"
#include "raster.h"

struct cue9_preview {
    r_dl dl;
    pip_scene scene;
    pip_opts opt;
};

cue9_preview *cue9_preview_create(uint32_t seed)
{
    cue9_preview *preview = calloc(1, sizeof(*preview));
    if (preview == NULL) return NULL;

    r_pal pal;
    memset(&pal, 0, sizeof(pal));
    pal.bg = (r_rgb){ 5, 10, 14 };
    pal.ink = pip_state_color(PIP_IDLE);

    r_dl_init(&preview->dl, &pal);
    r_set_swap(false);
    r_glow_enable(false);

    pip_scene_init(&preview->scene, seed ? seed : 1u);
    pip_opts_default(&preview->opt);
    preview->opt.rings = false;
    preview->opt.njob = 0;
    preview->opt.charging = true;
    preview->opt.effects = true;
    return preview;
}

void cue9_preview_destroy(cue9_preview *preview)
{
    free(preview);
}

void cue9_preview_reset(cue9_preview *preview)
{
    if (preview == NULL) return;
    pip_scene_reset(&preview->scene);
}

int cue9_preview_render(cue9_preview *preview, int state, float t, float dt,
                        const cue9_rgb *color, const cue9_rgb *background,
                        uint16_t *out, int out_len)
{
    if (preview == NULL || out == NULL) return R_ERR_PARAM;
    if (state < 0 || state >= PIP_NSTATE) return R_ERR_PARAM;
    if (out_len < R_W * R_H) return R_ERR_PARAM;

    preview->opt.has_color = color != NULL;
    if (color != NULL) {
        preview->opt.color = (r_rgb){ color->r, color->g, color->b };
    }
    preview->opt.has_bg = background != NULL;
    if (background != NULL) {
        preview->opt.bg = (r_rgb){ background->r, background->g, background->b };
    }

    r_dl_reset(&preview->dl);
    int rc = pip_scene_frame(&preview->dl, &preview->scene, state, t, dt,
                             &preview->opt);
    if (rc != R_OK) return rc;

    r_target target = {
        .px = out,
        .stride = R_W,
        .win = { .x0 = 0, .y0 = 0, .x1 = R_W, .y1 = R_H },
    };
    r_clear(&target, r_rgb565(preview->dl.pal.bg));
    return r_render(&preview->dl, &target, NULL, NULL);
}
