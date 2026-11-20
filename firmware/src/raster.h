/* raster.h — Pip renderer contract. C11, no dependencies, host- and device-buildable.
 *
 * Coordinates: device pixels, origin top-left, +x right, +y down.
 *   Pixel (i,j) covers the area [i,i+1) x [j,j+1). Coverage is EXACT AREA,
 *   so a shape lands on the same pixels as a canvas fill (no half-pixel shift).
 *   All ink lies inside r <= R_INK_R of (R_CX,R_CY); the disc r > R_CLIP_R is never touched.
 *
 * Two stages:
 *   build  — floats, matrices, flattening. Once per frame. Produces an r_dl. No pixels.
 *   render — int16 Q9.6 outlines -> pixels, for ONE window (band). Call per window/band.
 *   The render stage uses fixed static scratch (no malloc) and is NOT reentrant:
 *   call it from one task only.
 *
 * r_render output is independent of how the frame is cut into windows, including GLOW
 * (masks are extended past the window). The exception is a window border that cuts a
 * shape: that shape's coverage is clipped there, which is correct only if the scene did
 * not change at that border. The pipeline owns that choice.
 *
 * Design, tolerances and costs: renderer/notes/renderer-design.md.
 */
#ifndef RASTER_H
#define RASTER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- fixed panel geometry ------------------------------------------------- */
#define R_W 360
#define R_H 360
#define R_CX 180
#define R_CY 180
#define R_INK_R 173   /* every drawn pixel is inside this radius */
#define R_CLIP_R 178  /* hard disc clamp, no AA needed: ink stops at 173, glow ~<8/255 here */

/* ---- build limits. Overflow returns R_ERR_FULL; nothing is ever corrupted. - */
#define R_MAX_CMDS   128   /* peak Pip frame uses ~100 */
#define R_MAX_PTS    2560  /* peak frame flattens to ~980 edges = ~1960 pts */
#define R_MAX_CMD_PTS 384   /* points in one command; scene max measured 258 */
#define R_MAX_GLYPHS 128   /* 2 lines of 48 params.text chars + slack */
#define R_MAX_STACK  4     /* scene > face > part > glyph */

/* ---- tuning --------------------------------------------------------------- */
#define R_TOL_FLAT 0.25f   /* max chord deviation, DEVICE px, after all transforms */
#define R_GLOW_SCALE 0.5f  /* glow mask resolution vs device */

/* ---- result codes --------------------------------------------------------- */
enum { R_OK = 0, R_ERR_FULL = -1, R_ERR_PARAM = -2, R_ERR_STACK = -3 };

/* ---- basic types ---------------------------------------------------------- */
typedef struct { int16_t x0, y0, x1, y1; } r_rect; /* half-open, device px */

typedef struct {                /* 24-bit colour, the scene's source of truth */
  uint8_t r, g, b;
} r_rgb;

typedef struct { float a, b, c, d, e, f; } r_mat; /* x' = a*x + c*y + e ; y' = b*x + d*y + f */

typedef struct {
  uint16_t *px;     /* RGB565 at the WINDOW's top-left, not canvas (0,0) */
  int stride;       /* in uint16 units */
  r_rect win;       /* window in device px; render clips to this */
} r_target;          /* write = px[(y-win.y0)*stride + (x-win.x0)]; a 360x36
                      * band buffer needs no full-size framebuffer (pipeline:9). */

typedef struct {   /* the one state colour + 6 job colours + bg/battery/bolt, converted at cue change */
  r_rgb bg;
  r_rgb ink;                /* current state colour; set per cue, not per frame */
  r_rgb job[6]; int njob;
  r_rgb battery, bolt;
} r_pal;

/* ---- display list --------------------------------------------------------- */
typedef struct { uint16_t g; int16_t x, y; } r_glyph; /* g = glyph id; x,y = ink top-left, device px */

typedef struct {
  uint8_t  kind;    /* R_FILL | R_GLOW | R_TEXT | R_SPRITE */
  uint8_t  alpha;   /* 0..255 command alpha (canvas globalAlpha) */
  uint8_t  flags;   /* R_F_PREMIX */
  uint8_t  font;    /* R_FONT_* for R_TEXT */
  uint16_t first;   /* points: first index; text: first glyph index */
  uint16_t count;   /* points: count >= 3; text: glyph count */
  uint16_t rgb;     /* RGB565 source colour */
  uint16_t aux;     /* R_GLOW: sigma in 1/16 device px; else 0 */
  r_rect   bbox;    /* device px, already padded by 3*sigma for R_GLOW */
  const uint8_t *a8; /* R_SPRITE only: (bbox.w x bbox.h) 8-bit mask, stride = width */
} r_cmd;            /* 32 B */

#define R_F_PREMIX 0x01  /* fill is known to sit on the uniform bg: composited at build
                          * time and stored opaque. Wrong (visibly) if anything is behind it.
                          * Use only for keyboard body, ring track, job arcs. */

enum { R_FILL = 0, R_GLOW = 1, R_TEXT = 2, R_SPRITE = 3 };
enum { R_FONT_10 = 0, R_FONT_14 = 1, R_FONT_18 = 2, R_FONT_22 = 3 }; /* baked px em */
enum { R_ALIGN_L = 0, R_ALIGN_C = 1, R_ALIGN_R = 2 };

typedef struct {           /* ~14.9 KB; allocate statically, never on the stack */
  /* public so callers can allocate statically; treat fields as read-only */
  r_cmd   cmd[R_MAX_CMDS];   int ncmd;
  int16_t pt[R_MAX_PTS][2];  int npt;   /* Q9.6 device coords */
  r_glyph gl[R_MAX_GLYPHS];  int ngl;
  r_mat   m[R_MAX_STACK];    int sp;
  r_pal   pal;
  r_rgb   color;
  uint8_t alpha;             /* sticky command alpha, reset by r_dl_reset to 255 */
  uint8_t flags;             /* applied to the next command, then cleared */
  uint8_t glow_q;            /* halo for the next shape, then cleared; 0 = none */
  int8_t  err;
} r_dl;

/* ---- lifecycle ------------------------------------------------------------ */
void r_dl_init(r_dl *dl, const r_pal *pal);  /* zeroes, loads palette */
void r_dl_reset(r_dl *dl);                   /* ncmd=npt=ngl=0, sp=0, alpha=255, err=R_OK */

/* ---- build state ---------------------------------------------------------- */
void r_set_color(r_dl *dl, r_rgb c);                 /* sticky */
void r_set_alpha(r_dl *dl, uint8_t a);               /* sticky, 0..255 */
void r_set_premix(r_dl *dl, bool on);                /* next shape only, then cleared */
void r_set_glow(r_dl *dl, float sigma_px);           /* next shape: also emit a halo. 0=off */
void r_glow_enable(bool on);                           /* global kill switch for profiling */
void r_set_swap(bool on);                              /* store RGB565 byte-swapped for the panel */
void r_set_palette(r_dl *dl, const r_pal *pal);      /* on cue change */

/* Matrix stack, canvas order: each call applies to coordinates BEFORE the previous one.
 * Face:  r_translate(dl,180,132+y); r_rotate(dl,tilt); r_scale(dl,squash,1/squash);
 *        r_translate(dl,-180,-132);          (pip.js:389-390)
 * m[sp] is the current matrix; reset leaves sp=0 (identity, no saved levels).
 * r_push saves and increments; R_MAX_STACK live matrices = base + 3 pushes.
 * r_pop at sp==0 is a no-op that sets err. */
int  r_push(r_dl *dl);
int  r_pop(r_dl *dl);
void r_load_identity(r_dl *dl);
void r_translate(r_dl *dl, float tx, float ty);
void r_rotate(r_dl *dl, float rad);
void r_scale(r_dl *dl, float sx, float sy);
void r_concat(r_dl *dl, const r_mat *m);  /* current = current * m, as the calls above */

/* ---- shapes (user space; flattened in device space at R_TOL_FLAT) ----------
 * All emit one non-zero-winding closed outline. Points are bounded to the
 * device rect [-511,511) by Q9.6; the caller must keep geometry on/near canvas. */
int r_fill_rrect(r_dl *dl, float x, float y, float w, float h, float r);
int r_fill_ellipse(r_dl *dl, float cx, float cy, float rx, float ry);
int r_fill_poly(r_dl *dl, const float *xy, int n);   /* n >= 3, closed implicitly */
/* Polyline stroke -> single offset outline with round caps and round joins.
 * Closed joins the ends; this implementation limit is 256 input points.
 * w is device px at the current transform. One fill, no seams. */
int r_stroke_poly(r_dl *dl, const float *xy, int n, float w, bool closed);
/* Annular sector with butt ends: the ring primitive. a0,a1 radians, +x = 0, y-down
 * (canvas angle sense). Requires a1 > a0. Full circle = a1-a0 >= 2*pi - 1e-4;
 * w >= r collapses to a pie sector (inner radius clamps to 0). */
int r_fill_arc(r_dl *dl, float cx, float cy, float r, float w, float a0, float a1);

/* ---- text -----------------------------------------------------------------
 * Axis-aligned only. r_text() takes (x,y) as the text's vertical CENTRE, like
 * canvas textBaseline='middle'; r_text_baseline() takes y as the alphabetic
 * baseline (params.text uses baselines 316/328). The anchor is transformed by
 * the current CTM; glyphs remain upright. Proportional advances. Fits to maxw:
 * largest R_FONT_* <= font that fits, else ellipsized at R_FONT_10. maxw <= 0
 * disables fitting. Returns used width in px or R_ERR_*. Non-ASCII other than
 * U+2026 is rendered as '?'. Stored glyph ids are ASCII (or U+2026), lowercase
 * preserved. */
int r_text(r_dl *dl, int font, const char *utf8, float x, float y, int align, float maxw);
int r_text_baseline(r_dl *dl, int font, const char *utf8, float x, float y,
                    int align, float maxw);
float r_text_width(const r_dl *dl, int font, const char *utf8);  /* single line, no fit */

/* ---- sprites --------------------------------------------------------------
 * Axis-aligned A8 mask blit at device size: no rotation, no scaling, the current
 * CTM moves the top-left corner only. The mask is w*h bytes, row-major, stride = w,
 * 255 = opaque. Clipped to the window and the disc like any fill. The mask must
 * stay valid until r_render. */
int r_blit_a8(r_dl *dl, float x, float y, int w, int h, const uint8_t *mask);

/* ---- render --------------------------------------------------------------- */
typedef struct {
  uint32_t cmds;     /* commands whose bbox intersects this window */
  uint32_t edges;    /* fill outline points submitted (not per-row edges) */
  uint32_t rows;     /* row passes over fills/text/glow */
  uint32_t span_px;  /* pixels with nonzero coverage/mask */
  uint32_t blend_px; /* pixels actually blended */
  /* hot-path counters (appended; existing fields keep their meaning) */
  uint32_t edge_calls;  /* edge-row visits after row buckets/y-reject */
  uint32_t interp;      /* x interpolations (all int32, no int64 divide) */
  uint32_t area_div;    /* area_clamped divisions that remain */
  uint32_t fill_rows;   /* fill row passes inside the blend span */
  uint32_t glow_rows;   /* half-res glow mask row passes */
  uint32_t memset_bytes;/* coverage scratch bytes cleared (span-local) */
} r_stats;

void r_clear(r_target *t, uint16_t rgb565);  /* window ∩ disc only; corners stay untouched */

/* Renders the list into the window of *t. st/touched may be NULL.
 * touched = union of nonzero row spans (exact damage for this window), or {0,0,0,0}.
 * Single-threaded, fixed scratch. R_GLOW is built over the whole padded bbox, so
 * its output does not depend on the window split. */
int r_render(const r_dl *dl, r_target *t, r_stats *st, r_rect *touched);

/* Convert once per cue; the 8-bit fields are what the blender uses. */
uint16_t r_rgb565(r_rgb c);

#ifdef __cplusplus
}
#endif
#endif /* RASTER_H */
