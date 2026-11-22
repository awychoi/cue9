/* ambient.c - clock and weather pages. See ambient.h. */
#include "ambient.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#define PI_F 3.14159265358979323846f

static const r_rgb C_BG_CLOCK   = { 8, 17, 31 };
static const r_rgb C_BG_WEATHER = { 9, 21, 38 };
static const r_rgb C_CYAN       = { 100, 224, 236 };
static const r_rgb C_INK        = { 232, 243, 255 };
static const r_rgb C_BLUE       = { 124, 170, 255 };
static const r_rgb C_MUTED      = { 138, 164, 196 };
static const r_rgb C_DIM        = { 50, 68, 94 };
static const r_rgb C_TRACK      = { 27, 48, 74 };
static const r_rgb C_SUN        = { 242, 209, 143 };
static const r_rgb C_CLOUD      = { 212, 232, 255 };

/* Howard Hinnant's civil-from-days: days since 1970-01-01 -> Y/M/D. */
static void civil_from_days(int64_t z, int *y, int *m, int *d)
{
  z += 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  int64_t doe = z - era * 146097;
  int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t yr = yoe + era * 400;
  int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  int64_t mp = (5 * doy + 2) / 153;
  int64_t dd = doy - (153 * mp + 2) / 5 + 1;
  int64_t mm = mp < 10 ? mp + 3 : mp - 9;
  *y = (int)(yr + (mm <= 2));
  *m = (int)mm;
  *d = (int)dd;
}

/* The pipeline clears the disc with pal.bg before replaying the list, so the
 * page only has to claim the colour for the next clear. A full-disc fill here
 * cost ~40 ms a frame on the device for no visible gain. */
static void set_bg(r_dl *dl, r_rgb bg)
{
  dl->pal.bg = bg;
}

static void page_dots(r_dl *dl, int page)
{
  for (int i = 0; i < 3; i++) {
    int on = (i == page);
    r_set_color(dl, on ? C_CYAN : C_DIM);
    r_fill_ellipse(dl, 180.0f + (float)(i - 1) * 14.0f, 300.0f,
                   on ? 3.5f : 2.5f, on ? 3.5f : 2.5f);
  }
}

/* "AGENT WORKING" + its dot, centred as one unit. */
static void status_anchor(r_dl *dl, const char *label, r_rgb ink)
{
  float w = r_text_width(dl, R_FONT_10, label);
  float x0 = 180.0f - (7.0f + 6.0f + w) * 0.5f;
  r_set_color(dl, ink);
  r_fill_ellipse(dl, x0 + 3.5f, 76.0f, 3.5f, 3.5f);
  r_text(dl, R_FONT_10, label, x0 + 13.0f, 76.0f, R_ALIGN_L, 0);
}

static void clock_ticks(r_dl *dl, int sec)
{
  for (int i = 0; i < 60; i++) {
    float a = -PI_F / 2.0f + (float)i / 60.0f * 2.0f * PI_F;
    bool major = (i % 5) == 0;
    float r_out = 166.0f, r_in = major ? 153.0f : 160.0f;
    float xy[4] = {
      180.0f + cosf(a) * r_in, 180.0f + sinf(a) * r_in,
      180.0f + cosf(a) * r_out, 180.0f + sinf(a) * r_out,
    };
    r_set_color(dl, (i <= sec) ? C_CYAN : C_TRACK);
    r_stroke_poly(dl, xy, 2, major ? 3.0f : 1.5f, false);
  }
}

int amb_clock_frame(r_dl *dl, const amb_clock *clk, bool have_time,
                    const amb_wx *wx, const char *status, r_rgb status_ink,
                    int page, float t)
{
  char line[64];
  (void)t;
  r_load_identity(dl);
  r_set_alpha(dl, 255);
  r_set_glow(dl, 0);
  set_bg(dl, C_BG_CLOCK);

  int64_t local = have_time ? clk->local_epoch : 0;
  int64_t days = local >= 0 ? local / 86400 : (local - 86399) / 86400;
  int secs = (int)(local - days * 86400);
  int hh = secs / 3600, mm = (secs / 60) % 60, ss = secs % 60;

  clock_ticks(dl, have_time ? ss : -1);

  status_anchor(dl, status ? status : "AGENT IDLE", status_ink);

  if (have_time) {
    int hour = hh;
    if (!clk->fmt24) hour = hh % 12 ? hh % 12 : 12;
    snprintf(line, sizeof(line), "%02d:%02d", hour, mm);
  } else {
    snprintf(line, sizeof(line), "--:--");
  }
  r_set_color(dl, C_INK);
  r_text(dl, R_FONT_64, line, 180.0f, 154.0f, R_ALIGN_C, 0);

  if (have_time && !clk->fmt24) {
    r_set_color(dl, C_BLUE);
    r_text(dl, R_FONT_14, hh < 12 ? "AM" : "PM", 180.0f, 110.0f, R_ALIGN_C, 0);
  }

  if (have_time) {
    static const char *const wd[7] = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" };
    static const char *const mo[12] = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                                        "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" };
    int y, m, d;
    int wday = (int)(((days + 4) % 7 + 7) % 7);
    civil_from_days(days, &y, &m, &d);
    snprintf(line, sizeof(line), "%s \xC2\xB7 %s %d", wd[wday], mo[m - 1], d);
    r_set_color(dl, C_BLUE);
    r_text(dl, R_FONT_18, line, 180.0f, 212.0f, R_ALIGN_C, 0);
  }

  if (wx && wx->valid && wx->city[0]) {
    snprintf(line, sizeof(line), "%s \xC2\xB7 %d\xC2\xB0", wx->city, wx->temp);
  } else {
    snprintf(line, sizeof(line), "LOCAL TIME");
  }
  r_set_color(dl, C_MUTED);
  r_text(dl, R_FONT_14, line, 180.0f, 238.0f, R_ALIGN_C, 0);

  page_dots(dl, page);
  return dl->ncmd;
}

static void weather_icon(r_dl *dl, int code, float t)
{
  float bob = sinf(t * 2.2f) * 3.0f;
  if (code == AMB_SUNNY) {
    r_set_color(dl, C_SUN);
    r_fill_ellipse(dl, 180.0f, 108.0f + bob * 0.5f, 28.0f, 28.0f);
    return;
  }
  if (code == AMB_PARTLY) {
    r_set_color(dl, C_SUN);
    r_fill_ellipse(dl, 208.0f, 104.0f + bob * 0.5f, 22.0f, 22.0f);
  }
  r_set_color(dl, C_CLOUD);
  r_fill_ellipse(dl, 158.0f, 120.0f + bob, 20.0f, 20.0f);
  r_fill_ellipse(dl, 182.0f, 114.0f + bob, 24.0f, 24.0f);
  r_fill_ellipse(dl, 206.0f, 122.0f + bob, 17.0f, 17.0f);
  r_fill_rrect(dl, 150.0f, 118.0f + bob, 64.0f, 22.0f, 11.0f);

  if (code == AMB_RAIN) {
    r_set_color(dl, C_CYAN);
    for (int i = 0; i < 3; i++) {
      float ph = fmodf(t * 1.4f + (float)i * 0.33f, 1.0f);
      float x = 164.0f + (float)i * 16.0f;
      float y = 144.0f + ph * 12.0f;
      float xy[4] = { x, y, x - 2.0f, y + 5.0f };
      r_stroke_poly(dl, xy, 2, 2.5f, false);
    }
  } else if (code == AMB_SNOW) {
    r_set_color(dl, C_INK);
    for (int i = 0; i < 4; i++) {
      float ph = fmodf(t * 0.6f + (float)i * 0.25f, 1.0f);
      r_fill_ellipse(dl, 156.0f + (float)i * 16.0f, 144.0f + ph * 12.0f, 2.5f, 2.5f);
    }
  }
}

int amb_weather_frame(r_dl *dl, const amb_wx *wx, int page, float t)
{
  char line[64];
  r_load_identity(dl);
  r_set_alpha(dl, 255);
  r_set_glow(dl, 0);
  set_bg(dl, C_BG_WEATHER);

  if (!wx || !wx->valid) {
    r_set_color(dl, C_MUTED);
    r_text(dl, R_FONT_14, "WEATHER", 180.0f, 54.0f, R_ALIGN_C, 0);
    r_text(dl, R_FONT_18, "NO WEATHER YET", 180.0f, 186.0f, R_ALIGN_C, 0);
    page_dots(dl, page);
    return dl->ncmd;
  }

  static const char *const labels[4] = {
    "CLEAR & SUNNY", "PARTLY CLOUDY", "LIGHT RAIN", "SNOW SHOWERS"
  };
  int code = wx->code;
  if (code < 0 || code > 3) code = 1;

  r_set_color(dl, C_MUTED);
  r_text(dl, R_FONT_14, wx->city, 180.0f, 54.0f, R_ALIGN_C, 0);

  weather_icon(dl, code, t);

  snprintf(line, sizeof(line), "%d\xC2\xB0", wx->temp);
  r_set_color(dl, C_INK);
  r_text(dl, R_FONT_64, line, 180.0f, 188.0f, R_ALIGN_C, 0);

  r_set_color(dl, C_CYAN);
  r_text(dl, R_FONT_14, labels[code], 180.0f, 242.0f, R_ALIGN_C, 0);

  snprintf(line, sizeof(line), "H: %d\xC2\xB0   L: %d\xC2\xB0   FEELS %d\xC2\xB0",
           wx->hi, wx->lo, wx->feels);
  r_set_color(dl, C_MUTED);
  r_text(dl, R_FONT_10, line, 180.0f, 266.0f, R_ALIGN_C, 0);

  /* Day range on the bezel arc: a fixed scale so the band is comparable
   * day to day (10..100 F, -15..40 C), the low/high span, and a tick at the
   * current temperature. */
  float scale_lo = wx->unit == 'C' ? -15.0f : 10.0f;
  float scale_hi = wx->unit == 'C' ? 40.0f : 100.0f;
  float span_deg = scale_hi - scale_lo;
  float f_lo = ((float)wx->lo - scale_lo) / span_deg;
  float f_hi = ((float)wx->hi - scale_lo) / span_deg;
  float f_now = ((float)wx->temp - scale_lo) / span_deg;
  f_lo = f_lo < 0.0f ? 0.0f : (f_lo > 1.0f ? 1.0f : f_lo);
  f_hi = f_hi < 0.0f ? 0.0f : (f_hi > 1.0f ? 1.0f : f_hi);
  f_now = f_now < 0.0f ? 0.0f : (f_now > 1.0f ? 1.0f : f_now);
  if (f_hi < f_lo) {
    float t = f_lo;
    f_lo = f_hi;
    f_hi = t;
  }
  float mid = (f_lo + f_hi) * 0.5f;
  float span = f_hi - f_lo;
  if (span < 0.06f) span = 0.06f;               /* a one-degree day still reads */
  if (mid < span * 0.5f) mid = span * 0.5f;
  if (mid > 1.0f - span * 0.5f) mid = 1.0f - span * 0.5f;
  float f0 = mid - span * 0.5f;
  float f1 = mid + span * 0.5f;
  float a_lo = PI_F * (0.75f - 0.5f * f0);
  float a_hi = PI_F * (0.75f - 0.5f * f1);

  r_set_color(dl, C_TRACK);
  r_fill_arc(dl, 180.0f, 180.0f, 148.0f, 8.0f, PI_F * 0.25f, PI_F * 0.75f);
  r_set_color(dl, C_CYAN);
  r_fill_arc(dl, 180.0f, 180.0f, 148.0f, 8.0f, a_hi, a_lo);

  float a_now = PI_F * (0.75f - 0.5f * f_now);
  r_set_color(dl, C_INK);
  r_fill_ellipse(dl, 180.0f + cosf(a_now) * 148.0f, 180.0f + sinf(a_now) * 148.0f,
                 2.5f, 2.5f);

  page_dots(dl, page);
  return dl->ncmd;
}

r_rgb amb_page_bg(int page)
{
  return page == AMB_PAGE_WEATHER ? C_BG_WEATHER : C_BG_CLOCK;
}

void amb_clock_default(amb_clock *c)
{
  memset(c, 0, sizeof(*c));
  c->fmt24 = 0;
}

void amb_wx_default(amb_wx *w)
{
  memset(w, 0, sizeof(*w));
  w->code = AMB_PARTLY;
  w->unit = 'F';
}
