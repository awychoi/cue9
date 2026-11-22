/* ambient.h - the clock and weather pages, host/device buildable.
 *
 * These are not Pip faces: they are full-screen pages with their own palettes,
 * fed by the Pi's TIME and WX lines. The scene draws into the same r_dl as
 * pip_scene, so the pipeline, battery glyph and panel path are unchanged.
 *
 * The caller hands in local wall-clock seconds (UTC already offset) so this
 * module needs no timezone and no RTC: the Pi sends the offset with the time.
 */
#ifndef AMBIENT_H
#define AMBIENT_H

#include <stdbool.h>
#include <stdint.h>

#include "raster.h"

#ifdef __cplusplus
extern "C" {
#endif

enum { AMB_PAGE_LIVE = 0, AMB_PAGE_CLOCK = 1, AMB_PAGE_WEATHER = 2 };

enum { AMB_SUNNY = 0, AMB_PARTLY, AMB_RAIN, AMB_SNOW };

typedef struct {
  int64_t local_epoch;   /* seconds since 1970, local time */
  int fmt24;             /* 0 = 12-hour, 1 = 24-hour */
} amb_clock;

typedef struct {
  bool valid;
  int code;              /* AMB_SUNNY..AMB_SNOW */
  int temp, hi, lo, feels;
  char unit;             /* 'F' or 'C', from the Pi */
  char city[20];
} amb_wx;

void amb_clock_default(amb_clock *c);
void amb_wx_default(amb_wx *w);

/* page is AMB_PAGE_CLOCK or AMB_PAGE_WEATHER; it only picks the dots. */
int amb_clock_frame(r_dl *dl, const amb_clock *clk, bool have_time,
                    const amb_wx *wx, const char *status, r_rgb status_ink,
                    int page, float t);
int amb_weather_frame(r_dl *dl, const amb_wx *wx, int page, float t);

/* The page's clear colour, so the pipeline can clear before the first frame. */
r_rgb amb_page_bg(int page);

#ifdef __cplusplus
}
#endif
#endif /* AMBIENT_H */
