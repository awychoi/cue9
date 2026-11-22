/* Host wrapper for the device's clock and weather pages. */
#include "cue9_ambient.h"

#include <stdlib.h>
#include <string.h>

#include "ambient.h"
#include "raster.h"

struct cue9_ambient {
    r_dl dl;
};

cue9_ambient *cue9_ambient_create(void)
{
    cue9_ambient *ambient = calloc(1, sizeof(*ambient));
    if (ambient == NULL) return NULL;

    r_pal pal;
    memset(&pal, 0, sizeof(pal));
    pal.bg = (r_rgb){ 5, 10, 14 };
    pal.ink = (r_rgb){ 100, 224, 236 };

    r_set_swap(false);
    r_glow_enable(false);
    r_dl_init(&ambient->dl, &pal);
    return ambient;
}

void cue9_ambient_destroy(cue9_ambient *ambient)
{
    free(ambient);
}

int cue9_ambient_render(cue9_ambient *ambient, int page,
                        int64_t local_epoch, int fmt24, int have_time,
                        const char *status,
                        uint8_t status_r, uint8_t status_g, uint8_t status_b,
                        int weather_valid, int weather_code,
                        int weather_temp, int weather_hi, int weather_lo, int weather_feels,
                        char weather_unit, const char *weather_city,
                        float t, uint16_t *out, int out_len)
{
    if (ambient == NULL || out == NULL || out_len < R_W * R_H) return R_ERR_PARAM;
    if (page != AMB_PAGE_CLOCK && page != AMB_PAGE_WEATHER) return R_ERR_PARAM;

    amb_clock clk;
    amb_clock_default(&clk);
    clk.local_epoch = local_epoch;
    clk.fmt24 = fmt24 ? 1 : 0;

    amb_wx weather;
    amb_wx_default(&weather);
    weather.valid = weather_valid != 0;
    weather.code = weather_code;
    weather.temp = weather_temp;
    weather.hi = weather_hi;
    weather.lo = weather_lo;
    weather.feels = weather_feels;
    weather.unit = weather_unit;
    if (weather_city != NULL) {
        strncpy(weather.city, weather_city, sizeof(weather.city) - 1);
        weather.city[sizeof(weather.city) - 1] = '\0';
    }

    r_dl_reset(&ambient->dl);
    if (page == AMB_PAGE_CLOCK) {
        amb_clock_frame(
            &ambient->dl, &clk, have_time != 0,
            weather.valid ? &weather : NULL,
            status, (r_rgb){ status_r, status_g, status_b },
            AMB_PAGE_CLOCK, t
        );
    } else {
        amb_weather_frame(
            &ambient->dl, weather.valid ? &weather : NULL,
            AMB_PAGE_WEATHER, t
        );
    }

    r_target target = {
        .px = out,
        .stride = R_W,
        .win = { .x0 = 0, .y0 = 0, .x1 = R_W, .y1 = R_H },
    };
    r_clear(&target, r_rgb565(ambient->dl.pal.bg));
    return r_render(&ambient->dl, &target, NULL, NULL);
}
