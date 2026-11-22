/* raster.c — host prototype of the Pip raster core.
 *
 * Implements renderer/src/raster.h.  One pixel primitive: exact-area non-zero
 * polygon fill in int32 Q9.6 fixed point (no float on the render path).
 * rounded rect / ellipse / arc / stroke are outline builders; text and sprites
 * are A8 mask blits; glow is a half-res mask + separable [1 2 1] blur.
 *
 * Fill/glow rows use an edge bucket + active list (edges visited only on rows
 * they cross), 32-bit x interpolation, and a per-row dirty list so only the
 * columns actually written are cleared.
 *
 * Fixed scratch (no malloc, not reentrant):
 *   g_acc/g_suf      2896 B  per-row coverage accumulation
 *   g_glow          9216 B  half-res glow mask (96x96 worst case; device band-slices)
 *   sweep scratch  ~19.7 KB row heads, edge links, active list, x cache, dirty list
 *   font masks     20064 B  .rodata in font_baked.c (flash on device)
 * A device build slices the glow mask per band; see notes/core-report.md.
 */
#include "raster.h"
#include "font_baked.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#define R_PI 3.14159265358979323846f
#define R_TWO_PI 6.28318530717958647692f
#define R_Q 64            /* Q9.6 subunits per device px */
#define COV_FULL 4096     /* subunits^2 per full pixel */
#define R_STROKE_MAX 256  /* polyline points accepted by the stroke builder */
#define R_GLOW_MAX 96     /* half-res max; largest halo bbox is ~29x66 */

/* font.c private interface */
void r_font_init(void);
void r_font_metrics(int font, int *w, int *h, int *adv, int *cap, int *gap);
int r_font_glyph(int font, uint16_t cp, int *w, int *h, int *adv, int *bx, int *by);
const uint8_t *r_font_mask(int font, uint16_t cp, int *w, int *h);

static int32_t g_acc[R_W + 2];
static int32_t g_suf[R_W + 2];
static uint8_t g_glow[R_GLOW_MAX * R_GLOW_MAX];
static uint8_t g_grow[R_GLOW_MAX];
static uint8_t g_gcol[R_GLOW_MAX];
static int16_t g_halfw[R_H];
static int g_lut_ready;

/* Scanline sweep scratch: edges bucket by their first row, an active list is
 * compacted each row, and only columns actually written are cleared. */
static int16_t g_row_head[R_H + 1];     /* first edge index in this row, -1 = none */
static int16_t g_edge_next[R_MAX_CMD_PTS]; /* bucket/active link, -1 = end */
static uint16_t g_active[R_MAX_CMD_PTS];   /* dense edge indices crossing this row */
static int16_t g_xcache[R_MAX_CMD_PTS];    /* x at the last row-boundary crossed */
static uint8_t g_xvalid[R_MAX_CMD_PTS];
static uint16_t g_dirty[R_W];           /* columns touched this row */
static uint8_t g_dirty_flag[R_W];
static int g_ndirty;

/* stroke construction scratch (build stage, single-threaded) */
static float g_px[R_STROKE_MAX];
static float g_py[R_STROKE_MAX];
static float g_nx[R_STROKE_MAX];
static float g_ny[R_STROKE_MAX];

/* ---- small helpers -------------------------------------------------------- */

static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

static float clampf(float v, float lo, float hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

static uint16_t pack565(r_rgb c) {
  return (uint16_t)(((uint16_t)(c.r >> 3) << 11) |
                    ((uint16_t)(c.g >> 2) << 5) | (uint16_t)(c.b >> 3));
}

uint16_t r_rgb565(r_rgb c) { return pack565(c); }

static r_rgb expand565(uint16_t c) {
  r_rgb o;
  o.r = (uint8_t)(((c >> 11) & 31u) * 255u / 31u);
  o.g = (uint8_t)(((c >> 5) & 63u) * 255u / 63u);
  o.b = (uint8_t)((c & 31u) * 255u / 31u);
  return o;
}

static int blend8(int d, int s, int a) {
  return d + (((s - d) * a + 127) / 255);
}

static r_rgb premix_rgb(r_rgb dst, r_rgb src, int a) {
  r_rgb o;
  o.r = (uint8_t)clampi(blend8(dst.r, src.r, a), 0, 255);
  o.g = (uint8_t)clampi(blend8(dst.g, src.g, a), 0, 255);
  o.b = (uint8_t)clampi(blend8(dst.b, src.b, a), 0, 255);
  return o;
}

static bool g_swap_out;

static uint16_t bswap16(uint16_t v) {
  return (uint16_t)((v >> 8) | (v << 8));
}

void r_set_swap(bool on) { g_swap_out = on; }

static void blend_px(uint16_t *p, r_rgb s, int a) {
  r_rgb d;
  uint16_t cur;
  if (a <= 0) return;
  cur = g_swap_out ? bswap16(*p) : *p;
  if (a >= 255) {
    *p = g_swap_out ? bswap16(pack565(s)) : pack565(s);
    return;
  }
  d = expand565(cur);
  d.r = (uint8_t)clampi(blend8(d.r, s.r, a), 0, 255);
  d.g = (uint8_t)clampi(blend8(d.g, s.g, a), 0, 255);
  d.b = (uint8_t)clampi(blend8(d.b, s.b, a), 0, 255);
  {
    uint16_t v = pack565(d);
    *p = g_swap_out ? bswap16(v) : v;
  }
}

/* The target's px points at the window's top-left, not at canvas (0,0):
 * a band buffer (360x36) can be rendered without a full framebuffer. */
static uint16_t *target_px(const r_target *t, int x, int y) {
  return &t->px[(y - t->win.y0) * t->stride + (x - t->win.x0)];
}

/* ---- affine stack --------------------------------------------------------- */

static r_mat mat_mul(const r_mat *A, const r_mat *B) {
  r_mat o;
  o.a = A->a * B->a + A->c * B->b;
  o.b = A->b * B->a + A->d * B->b;
  o.c = A->a * B->c + A->c * B->d;
  o.d = A->b * B->c + A->d * B->d;
  o.e = A->a * B->e + A->c * B->f + A->e;
  o.f = A->b * B->e + A->d * B->f + A->f;
  return o;
}

static void xform(const r_dl *dl, float x, float y, float *ox, float *oy) {
  const r_mat *m = &dl->m[dl->sp];
  *ox = m->a * x + m->c * y + m->e;
  *oy = m->b * x + m->d * y + m->f;
}

/* ---- display list lifecycle ---------------------------------------------- */

void r_dl_init(r_dl *dl, const r_pal *pal) {
  if (!dl) return;
  memset(dl, 0, sizeof(*dl));
  dl->m[0].a = 1.0f;
  dl->m[0].d = 1.0f;
  dl->alpha = 255;
  if (pal) dl->pal = *pal;
  r_font_init();
}

void r_dl_reset(r_dl *dl) {
  if (!dl) return;
  dl->ncmd = 0;
  dl->npt = 0;
  dl->ngl = 0;
  dl->sp = 0;
  dl->m[0].a = 1.0f;
  dl->m[0].b = 0.0f;
  dl->m[0].c = 0.0f;
  dl->m[0].d = 1.0f;
  dl->m[0].e = 0.0f;
  dl->m[0].f = 0.0f;
  dl->alpha = 255;
  dl->flags = 0;
  dl->glow_q = 0;
  dl->err = R_OK;
}

void r_set_color(r_dl *dl, r_rgb c) { if (dl) dl->color = c; }
void r_set_alpha(r_dl *dl, uint8_t a) { if (dl) dl->alpha = a; }
void r_set_premix(r_dl *dl, bool on) { if (dl) dl->flags = on ? R_F_PREMIX : 0; }
static bool g_glow_on = true;

void r_glow_enable(bool on) { g_glow_on = on; }

void r_set_glow(r_dl *dl, float sigma_px) {
  if (!dl) return;
  if (!g_glow_on) { dl->glow_q = 0; return; }
  if (!isfinite(sigma_px) || sigma_px <= 0.0f) {
    dl->glow_q = 0;
    return;
  }
  sigma_px = clampf(sigma_px, 0.0f, 12.0f);
  dl->glow_q = (uint8_t)clampi((int)(sigma_px * 16.0f + 0.5f), 0, 192);
}
void r_set_palette(r_dl *dl, const r_pal *pal) { if (dl && pal) dl->pal = *pal; }

int r_push(r_dl *dl) {
  if (!dl) return R_ERR_PARAM;
  if (dl->sp >= R_MAX_STACK - 1) { dl->err = R_ERR_STACK; return R_ERR_STACK; }
  dl->m[dl->sp + 1] = dl->m[dl->sp];
  dl->sp++;
  return R_OK;
}

int r_pop(r_dl *dl) {
  if (!dl) return R_ERR_PARAM;
  if (dl->sp <= 0) { dl->err = R_ERR_STACK; return R_ERR_STACK; }
  dl->sp--;
  return R_OK;
}

void r_load_identity(r_dl *dl) {
  if (!dl) return;
  dl->m[dl->sp].a = 1.0f;
  dl->m[dl->sp].b = 0.0f;
  dl->m[dl->sp].c = 0.0f;
  dl->m[dl->sp].d = 1.0f;
  dl->m[dl->sp].e = 0.0f;
  dl->m[dl->sp].f = 0.0f;
}

void r_concat(r_dl *dl, const r_mat *m) {
  if (!dl || !m) return;
  dl->m[dl->sp] = mat_mul(&dl->m[dl->sp], m);
}

void r_translate(r_dl *dl, float tx, float ty) {
  r_mat t;
  if (!dl) return;
  t.a = 1.0f; t.b = 0.0f; t.c = 0.0f; t.d = 1.0f; t.e = tx; t.f = ty;
  dl->m[dl->sp] = mat_mul(&dl->m[dl->sp], &t);
}

void r_rotate(r_dl *dl, float rad) {
  r_mat t;
  float c, s;
  if (!dl) return;
  c = cosf(rad);
  s = sinf(rad);
  t.a = c; t.b = s; t.c = -s; t.d = c; t.e = 0.0f; t.f = 0.0f;
  dl->m[dl->sp] = mat_mul(&dl->m[dl->sp], &t);
}

void r_scale(r_dl *dl, float sx, float sy) {
  r_mat t;
  if (!dl) return;
  t.a = sx; t.b = 0.0f; t.c = 0.0f; t.d = sy; t.e = 0.0f; t.f = 0.0f;
  dl->m[dl->sp] = mat_mul(&dl->m[dl->sp], &t);
}

/* ---- points, commands ----------------------------------------------------- */

static int add_dev(r_dl *dl, float x, float y) {
  int32_t qx, qy;
  if (!isfinite(x) || !isfinite(y)) return R_ERR_PARAM;
  qx = (int32_t)floorf(x * (float)R_Q + 0.5f);
  qy = (int32_t)floorf(y * (float)R_Q + 0.5f);
  if (qx > 32767) qx = 32767;
  if (qx < -32768) qx = -32768;
  if (qy > 32767) qy = 32767;
  if (qy < -32768) qy = -32768;
  if (dl->npt > 0) {
    int16_t *last = dl->pt[dl->npt - 1];
    if (last[0] == (int16_t)qx && last[1] == (int16_t)qy) return R_OK;
  }
  if (dl->npt >= R_MAX_PTS) { dl->err = R_ERR_FULL; return R_ERR_FULL; }
  dl->pt[dl->npt][0] = (int16_t)qx;
  dl->pt[dl->npt][1] = (int16_t)qy;
  dl->npt++;
  return R_OK;
}

static int add_user(r_dl *dl, float x, float y) {
  float dx, dy;
  if (!isfinite(x) || !isfinite(y)) return R_ERR_PARAM;
  xform(dl, x, y, &dx, &dy);
  return add_dev(dl, dx, dy);
}

static int add_shape_cmd(r_dl *dl, int first, r_rgb color, uint8_t alpha,
                         uint8_t flags) {
  int n = dl->npt - first;
  int minx, miny, maxx, maxy;
  int glow = dl->glow_q;
  if (n < 3) {
    dl->npt = first;
    dl->glow_q = 0;
    dl->flags = 0;
    return R_ERR_PARAM;
  }
  while (n > 3) {
    int16_t *a = dl->pt[first];
    int16_t *b = dl->pt[first + n - 1];
    if (a[0] != b[0] || a[1] != b[1]) break;
    n--;
  }
  if (n > R_MAX_CMD_PTS) {
    dl->npt = first;
    dl->glow_q = 0;
    dl->flags = 0;
    dl->err = R_ERR_FULL;
    return R_ERR_FULL;
  }
  minx = miny = 32767;
  maxx = maxy = -32768;
  for (int i = 0; i < n; i++) {
    int x = dl->pt[first + i][0];
    int y = dl->pt[first + i][1];
    if (x < minx) minx = x;
    if (x > maxx) maxx = x;
    if (y < miny) miny = y;
    if (y > maxy) maxy = y;
  }
  dl->npt = first + n;
  {
    int need = glow ? 2 : 1;
    if (dl->ncmd + need > R_MAX_CMDS) {
      dl->npt = first;
      dl->glow_q = 0;
      dl->flags = 0;
      dl->err = R_ERR_FULL;
      return R_ERR_FULL;
    }
  }
  {
    int pad = 1;
    int gpad = 0;
    if (glow) {
      float sigma = (float)glow / 16.0f;
      gpad = (int)ceilf(3.0f * sigma) + 1;
    }
    if (glow) {
      r_cmd *g = &dl->cmd[dl->ncmd++];
      memset(g, 0, sizeof(*g));
      g->kind = R_GLOW;
      g->alpha = alpha;
      g->font = 0;
      g->first = (uint16_t)first;
      g->count = (uint16_t)n;
      g->rgb = pack565(color);
      g->aux = (uint16_t)glow;
      g->bbox.x0 = (int16_t)clampi((minx / R_Q) - gpad, -512, 511);
      g->bbox.y0 = (int16_t)clampi((miny / R_Q) - gpad, -512, 511);
      g->bbox.x1 = (int16_t)clampi(((maxx + R_Q - 1) / R_Q) + gpad, -512, 511);
      g->bbox.y1 = (int16_t)clampi(((maxy + R_Q - 1) / R_Q) + gpad, -512, 511);
    }
    {
      r_cmd *c = &dl->cmd[dl->ncmd++];
      r_rgb fillc = color;
      uint8_t fa = alpha;
      memset(c, 0, sizeof(*c));
      c->kind = R_FILL;
      c->flags = flags;
      c->rgb = pack565(fillc);
      if ((flags & R_F_PREMIX) && fa < 255) {
        fillc = premix_rgb(dl->pal.bg, color, fa);
        c->rgb = pack565(fillc);
        fa = 255;
      }
      c->alpha = fa;
      c->first = (uint16_t)first;
      c->count = (uint16_t)n;
      c->bbox.x0 = (int16_t)clampi((minx / R_Q) - pad, -512, 511);
      c->bbox.y0 = (int16_t)clampi((miny / R_Q) - pad, -512, 511);
      c->bbox.x1 = (int16_t)clampi(((maxx + R_Q - 1) / R_Q) + pad, -512, 511);
      c->bbox.y1 = (int16_t)clampi(((maxy + R_Q - 1) / R_Q) + pad, -512, 511);
    }
  }
  dl->glow_q = 0;
  dl->flags = 0;
  return R_OK;
}

/* ---- flattening ----------------------------------------------------------- */

static int flatten_cubic(r_dl *dl, float x0, float y0, float x1, float y1,
                         float x2, float y2, float x3, float y3, int depth) {
  float dx = x3 - x0, dy = y3 - y0;
  float len2 = dx * dx + dy * dy;
  float d1, d2;
  if (len2 < 1e-12f) {
    d1 = fabsf(x1 - x0) + fabsf(y1 - y0);
    d2 = fabsf(x2 - x0) + fabsf(y2 - y0);
  } else {
    float inv = 1.0f / sqrtf(len2);
    d1 = fabsf((x1 - x0) * dy - (y1 - y0) * dx) * inv;
    d2 = fabsf((x2 - x0) * dy - (y2 - y0) * dx) * inv;
  }
  if (depth >= 16 || (d1 <= R_TOL_FLAT && d2 <= R_TOL_FLAT))
    return add_dev(dl, x3, y3);
  {
    float ax = (x0 + x1) * 0.5f, ay = (y0 + y1) * 0.5f;
    float bx = (x1 + x2) * 0.5f, by = (y1 + y2) * 0.5f;
    float cx = (x2 + x3) * 0.5f, cy = (y2 + y3) * 0.5f;
    float dx1 = (ax + bx) * 0.5f, dy1 = (ay + by) * 0.5f;
    float dx2 = (bx + cx) * 0.5f, dy2 = (by + cy) * 0.5f;
    float mx = (dx1 + dx2) * 0.5f, my = (dy1 + dy2) * 0.5f;
    int rc = flatten_cubic(dl, x0, y0, ax, ay, dx1, dy1, mx, my, depth + 1);
    if (rc != R_OK) return rc;
    return flatten_cubic(dl, mx, my, dx2, dy2, cx, cy, x3, y3, depth + 1);
  }
}

/* Emit an ellipse arc as transformed cubics.  (cx,cy,rx,ry,a0,a1) in user
 * space; sweeps longer than 90 deg are split.  push_start controls whether the
 * current point is added first. */
static int arc_user(r_dl *dl, float cx, float cy, float rx, float ry,
                    float a0, float a1, int push_start) {
  float sweep = a1 - a0;
  float step, a;
  int segs;
  if (!isfinite(cx) || !isfinite(cy) || !isfinite(rx) || !isfinite(ry) ||
      !isfinite(a0) || !isfinite(a1))
    return R_ERR_PARAM;
  if (rx == 0.0f || ry == 0.0f) return R_ERR_PARAM;
  if (sweep == 0.0f) return R_ERR_PARAM;
  segs = (int)ceilf(fabsf(sweep) / (R_PI * 0.5f));
  if (segs < 1) segs = 1;
  if (segs > 8) segs = 8;
  step = sweep / (float)segs;
  if (push_start) {
    int rc = add_user(dl, cx + rx * cosf(a0), cy + ry * sinf(a0));
    if (rc != R_OK) return rc;
  }
  a = a0;
  for (int i = 0; i < segs; i++) {
    float b = a + step;
    float ka = cosf(a), sa = sinf(a), kb = cosf(b), sb = sinf(b);
    float k = (4.0f / 3.0f) * tanf(step * 0.25f);
    float p0x = cx + rx * ka, p0y = cy + ry * sa;
    float p3x = cx + rx * kb, p3y = cy + ry * sb;
    float p1x = p0x + k * (-rx * sa), p1y = p0y + k * (ry * ka);
    float p2x = p3x - k * (-rx * sb), p2y = p3y - k * (ry * kb);
    float d0x, d0y, d1x, d1y, d2x, d2y, d3x, d3y;
    int rc;
    xform(dl, p0x, p0y, &d0x, &d0y);
    xform(dl, p1x, p1y, &d1x, &d1y);
    xform(dl, p2x, p2y, &d2x, &d2y);
    xform(dl, p3x, p3y, &d3x, &d3y);
    (void)d0x; (void)d0y;
    rc = flatten_cubic(dl, d0x, d0y, d1x, d1y, d2x, d2y, d3x, d3y, 0);
    if (rc != R_OK) return rc;
    a = b;
  }
  return R_OK;
}

/* ---- fill builders -------------------------------------------------------- */

int r_fill_poly(r_dl *dl, const float *xy, int n) {
  int first;
  if (!dl || !xy || n < 3) return R_ERR_PARAM;
  first = dl->npt;
  for (int i = 0; i < n; i++) {
    int rc = add_user(dl, xy[2 * i], xy[2 * i + 1]);
    if (rc != R_OK) { dl->npt = first; dl->glow_q = 0; return rc; }
  }
  return add_shape_cmd(dl, first, dl->color, dl->alpha, dl->flags);
}

int r_fill_rrect(r_dl *dl, float x, float y, float w, float h, float r) {
  int first;
  float rr;
  if (!dl || !isfinite(x) || !isfinite(y) || !isfinite(w) || !isfinite(h) ||
      !isfinite(r) || w <= 0.0f || h <= 0.0f)
    return R_ERR_PARAM;
  rr = clampf(r, 0.0f, fminf(w, h) * 0.5f);
  first = dl->npt;
  if (rr < 1e-4f) {
    static const float corner[8] = { 0, 0, 1, 0, 1, 1, 0, 1 };
    for (int i = 0; i < 4; i++) {
      int rc = add_user(dl, x + corner[2 * i] * w, y + corner[2 * i + 1] * h);
      if (rc != R_OK) { dl->npt = first; dl->glow_q = 0; return rc; }
    }
  } else {
    int rc;
    rc = add_user(dl, x + rr, y);
    if (rc == R_OK) rc = add_user(dl, x + w - rr, y);
    if (rc == R_OK)
      rc = arc_user(dl, x + w - rr, y + rr, rr, rr, -R_PI * 0.5f, 0.0f, 0);
    if (rc == R_OK) rc = add_user(dl, x + w, y + h - rr);
    if (rc == R_OK)
      rc = arc_user(dl, x + w - rr, y + h - rr, rr, rr, 0.0f, R_PI * 0.5f, 0);
    if (rc == R_OK) rc = add_user(dl, x + rr, y + h);
    if (rc == R_OK)
      rc = arc_user(dl, x + rr, y + h - rr, rr, rr, R_PI * 0.5f, R_PI, 0);
    if (rc == R_OK) rc = add_user(dl, x, y + rr);
    if (rc == R_OK)
      rc = arc_user(dl, x + rr, y + rr, rr, rr, R_PI, R_PI * 1.5f, 0);
    if (rc != R_OK) { dl->npt = first; dl->glow_q = 0; return rc; }
  }
  return add_shape_cmd(dl, first, dl->color, dl->alpha, dl->flags);
}

int r_fill_ellipse(r_dl *dl, float cx, float cy, float rx, float ry) {
  int first, rc;
  if (!dl || !isfinite(cx) || !isfinite(cy) || !isfinite(rx) || !isfinite(ry) ||
      rx <= 0.0f || ry <= 0.0f)
    return R_ERR_PARAM;
  first = dl->npt;
  rc = arc_user(dl, cx, cy, rx, ry, 0.0f, R_TWO_PI, 1);
  if (rc != R_OK) { dl->npt = first; dl->glow_q = 0; return rc; }
  return add_shape_cmd(dl, first, dl->color, dl->alpha, dl->flags);
}

int r_fill_arc(r_dl *dl, float cx, float cy, float r, float w, float a0, float a1) {
  int first, rc;
  float inner, delta;
  if (!dl || !isfinite(cx) || !isfinite(cy) || !isfinite(r) || !isfinite(w) ||
      !isfinite(a0) || !isfinite(a1) || r <= 0.0f || w <= 0.0f)
    return R_ERR_PARAM;
  delta = a1 - a0;
  if (delta <= 0.0f) return R_ERR_PARAM;
  if (delta >= R_TWO_PI - 1e-4f) {
    delta = R_TWO_PI;
    a1 = a0 + R_TWO_PI;
  }
  inner = r - w;
  if (inner < 1e-4f) inner = 0.0f;
  first = dl->npt;
  rc = arc_user(dl, cx, cy, r, r, a0, a1, 1);
  if (rc == R_OK && inner > 0.0f) {
    rc = add_user(dl, cx + inner * cosf(a1), cy + inner * sinf(a1));
    if (rc == R_OK) rc = arc_user(dl, cx, cy, inner, inner, a1, a0, 0);
  } else if (rc == R_OK) {
    rc = add_user(dl, cx, cy);
  }
  if (rc != R_OK) { dl->npt = first; dl->glow_q = 0; return rc; }
  return add_shape_cmd(dl, first, dl->color, dl->alpha, dl->flags);
}

/* ---- stroke builder ------------------------------------------------------- */

static int dot_dev(r_dl *dl, float cx, float cy, float r) {
  int first = dl->npt;
  int n = 20;
  if (r <= 0.0f) return R_ERR_PARAM;
  for (int i = 0; i < n; i++) {
    float a = R_TWO_PI * (float)i / (float)n;
    int rc = add_dev(dl, cx + r * cosf(a), cy + r * sinf(a));
    if (rc != R_OK) { dl->npt = first; dl->glow_q = 0; return rc; }
  }
  return add_shape_cmd(dl, first, dl->color, dl->alpha, dl->flags);
}

static int arc_dev_append(r_dl *dl, float cx, float cy, float r,
                          float a0, float delta, int min_steps) {
  float ad = fabsf(delta);
  float step;
  int n;
  if (ad < 1e-5f) return R_OK;
  step = (r <= R_TOL_FLAT) ? (R_PI * 0.5f)
                           : 2.0f * acosf(clampf(1.0f - R_TOL_FLAT / r, -1.0f, 1.0f));
  if (step < 0.02f) step = 0.02f;
  n = (int)ceilf(ad / step);
  if (n < min_steps) n = min_steps;
  if (n > 64) n = 64;
  for (int i = 1; i <= n; i++) {
    float a = a0 + delta * (float)i / (float)n;
    int rc = add_dev(dl, cx + r * cosf(a), cy + r * sinf(a));
    if (rc != R_OK) return rc;
  }
  return R_OK;
}

static int round_join(r_dl *dl, float cx, float cy, float r,
                      const float *nf, const float *nt) {
  float a0 = atan2f(nf[1], nf[0]);
  float a1 = atan2f(nt[1], nt[0]);
  float d = a1 - a0;
  while (d > R_PI) d -= R_TWO_PI;
  while (d < -R_PI) d += R_TWO_PI;
  if (fabsf(d) < 1e-4f) return R_OK;
  return arc_dev_append(dl, cx, cy, r, a0, d, 2);
}

static int round_cap(r_dl *dl, float cx, float cy, float r,
                     const float *from, const float *to, float tx, float ty) {
  float a0 = atan2f(from[1], from[0]);
  float mid = a0 + R_PI * 0.5f;
  float d;
  /* two candidate half turns; pick the one whose midpoint points along t */
  if (cosf(mid) * tx + sinf(mid) * ty >= 0.0f) d = R_PI;
  else d = -R_PI;
  (void)to;
  return arc_dev_append(dl, cx, cy, r, a0, d, 4);
}

static void normal_of(float x0, float y0, float x1, float y1, float *nx, float *ny) {
  float dx = x1 - x0, dy = y1 - y0;
  float inv = 1.0f / sqrtf(dx * dx + dy * dy);
  *nx = -dy * inv;
  *ny = dx * inv;
}

int r_stroke_poly(r_dl *dl, const float *xy, int n, float w, bool closed) {
  int m = 0, first, rc = R_OK;
  float r;
  if (!dl || !xy || n < 1 || !isfinite(w) || w <= 0.0f) return R_ERR_PARAM;
  if (n > R_STROKE_MAX) return R_ERR_FULL;
  r = w * 0.5f;
  /* transform + dedupe */
  for (int i = 0; i < n; i++) {
    float x, y;
    if (!isfinite(xy[2 * i]) || !isfinite(xy[2 * i + 1])) return R_ERR_PARAM;
    xform(dl, xy[2 * i], xy[2 * i + 1], &x, &y);
    if (m > 0) {
      float dx = x - g_px[m - 1], dy = y - g_py[m - 1];
      if (dx * dx + dy * dy < 1e-6f) continue;
    }
    g_px[m] = x;
    g_py[m] = y;
    m++;
  }
  if (closed && m > 1) {
    float dx = g_px[m - 1] - g_px[0], dy = g_py[m - 1] - g_py[0];
    if (dx * dx + dy * dy < 1e-6f) m--;
  }
  if (m <= 0) return R_ERR_PARAM;
  if (m == 1) return dot_dev(dl, g_px[0], g_py[0], r);
  {
    int segs = closed ? m : m - 1;
    for (int i = 0; i < segs; i++) {
      int j = (i + 1) % m;
      normal_of(g_px[i], g_py[i], g_px[j], g_py[j], &g_nx[i], &g_ny[i]);
    }
  }
  first = dl->npt;
  if (!closed) {
    /* left side forward, end cap, right side back, start cap */
    rc = add_dev(dl, g_px[0] + g_nx[0] * r, g_py[0] + g_ny[0] * r);
    for (int i = 0; i < m - 1 && rc == R_OK; i++) {
      if (i > 0) {
        float nf[2] = { g_nx[i - 1], g_ny[i - 1] };
        float nt[2] = { g_nx[i], g_ny[i] };
        rc = round_join(dl, g_px[i], g_py[i], r, nf, nt);
      }
      if (rc == R_OK)
        rc = add_dev(dl, g_px[i + 1] + g_nx[i] * r, g_py[i + 1] + g_ny[i] * r);
    }
    if (rc == R_OK) {
      float from[2] = { g_nx[m - 2], g_ny[m - 2] };
      float to[2] = { -g_nx[m - 2], -g_ny[m - 2] };
      float tx = g_px[m - 1] - g_px[m - 2];
      float ty = g_py[m - 1] - g_py[m - 2];
      float inv = 1.0f / sqrtf(tx * tx + ty * ty);
      rc = round_cap(dl, g_px[m - 1], g_py[m - 1], r, from, to,
                     tx * inv, ty * inv);
    }
    for (int i = m - 2; i >= 1 && rc == R_OK; i--) {
      rc = add_dev(dl, g_px[i] - g_nx[i] * r, g_py[i] - g_ny[i] * r);
      if (rc == R_OK) {
        float nf[2] = { -g_nx[i], -g_ny[i] };
        float nt[2] = { -g_nx[i - 1], -g_ny[i - 1] };
        rc = round_join(dl, g_px[i], g_py[i], r, nf, nt);
      }
    }
    if (rc == R_OK)
      rc = add_dev(dl, g_px[0] - g_nx[0] * r, g_py[0] - g_ny[0] * r);
    if (rc == R_OK) {
      float from[2] = { -g_nx[0], -g_ny[0] };
      float to[2] = { g_nx[0], g_ny[0] };
      float tx = -(g_px[1] - g_px[0]);
      float ty = -(g_py[1] - g_py[0]);
      float inv = 1.0f / sqrtf(tx * tx + ty * ty);
      rc = round_cap(dl, g_px[0], g_py[0], r, from, to, tx * inv, ty * inv);
    }
  } else {
    /* outer left loop, bridge, inner loop traversed in reverse */
    rc = add_dev(dl, g_px[0] + g_nx[m - 1] * r, g_py[0] + g_ny[m - 1] * r);
    for (int j = 0; j < m && rc == R_OK; j++) {
      int ip = (j + m - 1) % m;
      float nf[2] = { g_nx[ip], g_ny[ip] };
      float nt[2] = { g_nx[j], g_ny[j] };
      rc = round_join(dl, g_px[j], g_py[j], r, nf, nt);
      if (rc == R_OK && j + 1 < m) {
        int jn = j + 1;
        rc = add_dev(dl, g_px[jn] + g_nx[j] * r, g_py[jn] + g_ny[j] * r);
      }
    }
    if (rc == R_OK) {
      rc = add_dev(dl, g_px[0] + g_nx[m - 1] * r,
                   g_py[0] + g_ny[m - 1] * r);
    }
    if (rc == R_OK) {
      rc = add_dev(dl, g_px[0] - g_nx[m - 1] * r,
                   g_py[0] - g_ny[m - 1] * r);
    }
    for (int j = m - 1; j >= 1 && rc == R_OK; j--) {
      rc = add_dev(dl, g_px[j] - g_nx[j] * r, g_py[j] - g_ny[j] * r);
      if (rc == R_OK) {
        float nf[2] = { -g_nx[j], -g_ny[j] };
        float nt[2] = { -g_nx[j - 1], -g_ny[j - 1] };
        rc = round_join(dl, g_px[j], g_py[j], r, nf, nt);
      }
    }
    if (rc == R_OK)
      rc = add_dev(dl, g_px[0] - g_nx[0] * r, g_py[0] - g_ny[0] * r);
    if (rc == R_OK) {
      float nf[2] = { -g_nx[0], -g_ny[0] };
      float nt[2] = { -g_nx[m - 1], -g_ny[m - 1] };
      rc = round_join(dl, g_px[0], g_py[0], r, nf, nt);
    }
  }
  if (rc != R_OK) { dl->npt = first; dl->glow_q = 0; return rc; }
  return add_shape_cmd(dl, first, dl->color, dl->alpha, dl->flags);
}

/* ---- text ----------------------------------------------------------------- */

static uint32_t utf8_next(const unsigned char **pp) {
  const unsigned char *p = *pp;
  uint32_t cp;
  int extra;
  if (*p == 0) return 0;
  if (p[0] < 0x80u) { cp = p[0]; extra = 0; }
  else if ((p[0] & 0xE0u) == 0xC0u) { cp = p[0] & 0x1Fu; extra = 1; }
  else if ((p[0] & 0xF0u) == 0xE0u) { cp = p[0] & 0x0Fu; extra = 2; }
  else if ((p[0] & 0xF8u) == 0xF0u) { cp = p[0] & 0x07u; extra = 3; }
  else { *pp = p + 1; return 0xFFFDu; }
  for (int i = 0; i < extra; i++) {
    if ((p[i + 1] & 0xC0u) != 0x80u) { *pp = p + 1; return 0xFFFDu; }
    cp = (cp << 6) | (p[i + 1] & 0x3Fu);
  }
  if ((extra == 1 && cp < 0x80u) || (extra == 2 && cp < 0x800u) ||
      (extra == 3 && cp < 0x10000u)) {
    *pp = p + 1;
    return 0xFFFDu;
  }
  *pp = p + 1 + extra;
  return cp;
}

static uint16_t text_gid(uint32_t cp) {
  if (cp == 0x2026u) return 0x2026u;
  if (cp == 0x00B0u || cp == 0x00B7u) return (uint16_t)cp;
  if (cp == (uint32_t)'\t' || cp == (uint32_t)'\n' || cp == (uint32_t)'\r')
    cp = (uint32_t)' ';
  if (cp < 32u || cp > 126u) cp = (uint32_t)'?';
  return (uint16_t)cp;
}

/* Width = sum of integer advances; no kerning.  Also returns cap/ascent/descent
 * for the face, so callers can place a baseline or a cap-height centre. */
static int text_measure(int font, const uint16_t *cps, int n, int *cap,
                        int *asc, int *desc) {
  int total = 0, adv;
  for (int i = 0; i < n; i++) {
    r_font_glyph(font, cps[i], NULL, NULL, &adv, NULL, NULL);
    total += adv;
  }
  r_font_metrics(font, NULL, NULL, NULL, cap, NULL);
  if (asc || desc) {
    int a = 0, d = 0;
    r_font_metrics(font, NULL, &a, NULL, NULL, &d);
    if (asc) *asc = a;
    if (desc) *desc = d;
  }
  return total;
}

float r_text_width(const r_dl *dl, int font, const char *utf8) {
  int n = 0, w;
  uint16_t cps[R_MAX_GLYPHS];
  const unsigned char *p;
  (void)dl;
  if (!utf8 || font < 0 || font >= R_FONT_NFACE) return 0.0f;
  p = (const unsigned char *)utf8;
  while (*p) {
    uint32_t cp = utf8_next(&p);
    if (cp == 0) break;
    if (n >= R_MAX_GLYPHS) break;
    cps[n++] = text_gid(cp);
  }
  if (n == 0) return 0.0f;
  w = text_measure(font, cps, n, NULL, NULL, NULL);
  return (float)w;
}

static int text_common(r_dl *dl, int font, const char *utf8, float x, float y,
                       int align, float maxw, bool baseline) {
  uint16_t cps[R_MAX_GLYPHS];
  int n = 0, w, cap = 0, asc = 0, desc = 0, used, use, limit;
  int startx, baseline_y, first_gl, i, pen;
  float ax, ay;
  const unsigned char *p;
  r_rgb color;
  uint8_t alpha;
  if (!dl || !utf8 || font < 0 || font >= R_FONT_NFACE || align < 0 || align > 2)
    return R_ERR_PARAM;
  if (!isfinite(x) || !isfinite(y) || !isfinite(maxw)) return R_ERR_PARAM;
  p = (const unsigned char *)utf8;
  while (*p) {
    uint32_t cp = utf8_next(&p);
    if (cp == 0) break;
    if (n >= R_MAX_GLYPHS) return R_ERR_FULL;
    cps[n++] = text_gid(cp);
  }
  if (n == 0) {
    dl->flags = 0;
    dl->glow_q = 0;
    return 0;
  }
  limit = (maxw > 0.0f) ? (int)floorf(maxw) : 0;
  w = text_measure(font, cps, n, &cap, &asc, &desc);
  use = font;
  if (limit > 0 && w > limit) {
    int found = -1;
    for (int f = font; f >= 0; f--) {
      if (text_measure(f, cps, n, NULL, NULL, NULL) <= limit) { found = f; break; }
    }
    if (found >= 0) {
      use = found;
      w = text_measure(use, cps, n, &cap, &asc, &desc);
    } else {
      int ew, keep, prefix;
      use = 0;
      r_font_glyph(use, 0x2026u, NULL, NULL, &ew, NULL, NULL);
      if (ew > limit) return 0;
      keep = n;
      prefix = text_measure(use, cps, keep, NULL, NULL, NULL);
      while (keep > 0 && prefix + ew > limit) {
        keep--;
        prefix = text_measure(use, cps, keep, NULL, NULL, NULL);
      }
      cps[keep] = 0x2026u;
      n = keep + 1;
      w = text_measure(use, cps, n, &cap, &asc, &desc);
    }
  }
  used = w;
  xform(dl, x, y, &ax, &ay);
  if (!isfinite(ax) || !isfinite(ay)) return R_ERR_PARAM;
  if (ax < -4096.0f || ax > 4096.0f || ay < -4096.0f || ay > 4096.0f)
    return used;
  {
    int ix = (int)floorf(ax + 0.5f);
    int iy = (int)floorf(ay + 0.5f);
    if (align == R_ALIGN_C) startx = ix - used / 2;
    else if (align == R_ALIGN_R) startx = ix - used;
    else startx = ix;
    baseline_y = baseline ? iy : iy + cap / 2;
  }
  if (dl->ngl + n > R_MAX_GLYPHS) {
    dl->err = R_ERR_FULL;
    return R_ERR_FULL;
  }
  if (dl->ncmd >= R_MAX_CMDS) { dl->err = R_ERR_FULL; return R_ERR_FULL; }
  first_gl = dl->ngl;
  pen = startx;
  for (i = 0; i < n; i++) {
    int gw, gh, adv, bx, by;
    r_font_glyph(use, cps[i], &gw, &gh, &adv, &bx, &by);
    dl->gl[dl->ngl].g = cps[i];
    dl->gl[dl->ngl].x = (int16_t)clampi(pen + bx, -32768, 32767);
    dl->gl[dl->ngl].y = (int16_t)clampi(baseline_y + by, -32768, 32767);
    dl->ngl++;
    pen += adv;
  }
  color = dl->color;
  alpha = dl->alpha;
  {
    r_cmd *c = &dl->cmd[dl->ncmd++];
    memset(c, 0, sizeof(*c));
    c->kind = R_TEXT;
    c->alpha = alpha;
    c->font = (uint8_t)use;
    c->first = (uint16_t)first_gl;
    c->count = (uint16_t)n;
    c->rgb = pack565(color);
    c->bbox.x0 = (int16_t)clampi(startx - 2, -512, 511);
    c->bbox.y0 = (int16_t)clampi(baseline_y - asc - 2, -512, 511);
    c->bbox.x1 = (int16_t)clampi(startx + used + 2, -512, 511);
    c->bbox.y1 = (int16_t)clampi(baseline_y + desc + 2, -512, 511);
  }
  dl->flags = 0;
  dl->glow_q = 0;
  return used;
}

int r_text(r_dl *dl, int font, const char *utf8, float x, float y, int align,
           float maxw) {
  return text_common(dl, font, utf8, x, y, align, maxw, false);
}

int r_text_baseline(r_dl *dl, int font, const char *utf8, float x, float y,
                    int align, float maxw) {
  return text_common(dl, font, utf8, x, y, align, maxw, true);
}

int r_blit_a8(r_dl *dl, float x, float y, int w, int h, const uint8_t *mask) {
  float ax, ay;
  int ix, iy;
  r_cmd *c;
  if (!dl || !mask || w <= 0 || h <= 0) return R_ERR_PARAM;
  if (!isfinite(x) || !isfinite(y)) return R_ERR_PARAM;
  xform(dl, x, y, &ax, &ay);
  if (!isfinite(ax) || !isfinite(ay)) return R_ERR_PARAM;
  if (ax < -16384.0f || ax > 16384.0f || ay < -16384.0f || ay > 16384.0f)
    return R_OK;
  ix = (int)floorf(ax + 0.5f);
  iy = (int)floorf(ay + 0.5f);
  if (dl->ncmd >= R_MAX_CMDS) { dl->err = R_ERR_FULL; return R_ERR_FULL; }
  c = &dl->cmd[dl->ncmd++];
  memset(c, 0, sizeof(*c));
  c->kind = R_SPRITE;
  c->alpha = dl->alpha;
  c->rgb = pack565(dl->color);
  c->a8 = mask;
  c->bbox.x0 = (int16_t)clampi(ix, -32768, 32767);
  c->bbox.y0 = (int16_t)clampi(iy, -32768, 32767);
  c->bbox.x1 = (int16_t)clampi(ix + w, -32768, 32767);
  c->bbox.y1 = (int16_t)clampi(iy + h, -32768, 32767);
  dl->flags = 0;
  dl->glow_q = 0;
  return R_OK;
}

/* ---- rasteriser ----------------------------------------------------------- */

static void ensure_lut(void) {
  if (g_lut_ready) return;
  for (int y = 0; y < R_H; y++) {
    float dy = (float)y + 0.5f - (float)R_CY;
    float d = (float)R_CLIP_R * (float)R_CLIP_R - dy * dy;
    g_halfw[y] = (d <= 0.0f) ? 0 : (int16_t)floorf(sqrtf(d));
  }
  g_lut_ready = 1;
}

/* x at y from the same line equation as before, but 32-bit.  Q9.6 point
 * differences are <= 65535, so |dx*dy| <= 0xFFFE0001 and the exact rounded
 * result fits a uint32; no int64 divide appears in the per-row path. */
static int32_t interp_x32(int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                          int32_t y, r_stats *st) {
  int32_t dx = x1 - x0, dy = y1 - y0, ny = y - y0;
  uint32_t ax, ay, d, m, q;
  int neg;
  if (dy == 0) return x0;
  neg = ((dx < 0) != (ny < 0));
  if (dy < 0) { neg = !neg; dy = -dy; }
  ax = (uint32_t)(dx < 0 ? -dx : dx);
  ay = (uint32_t)(ny < 0 ? -ny : ny);
  m = ax * ay;
  d = (uint32_t)dy;
  q = (m + d / 2u) / d;
  st->interp++;
  return x0 + (neg ? -(int32_t)q : (int32_t)q);
}

static int32_t h2_32(int32_t u) {
  if (u <= 0) return 0;
  if (u >= R_Q) return 2 * R_Q * u - R_Q * R_Q;
  return u * u;
}

/* Exact-area cell contribution.  u0..u1 and dy are bounded by the Q9.6
 * coordinate range, so the products fit int32. */
static int32_t area_clamped32(int32_t u0, int32_t u1, int32_t dy,
                              r_stats *st) {
  int32_t du, num, den;
  if (u1 == u0) {
    int32_t u = u0;
    if (u < 0) u = 0;
    if (u > R_Q) u = R_Q;
    return dy * u;
  }
  /* Both ends inside one pixel column: the secant of H2 is (u0+u1)/2. */
  if (u0 >= 0 && u1 >= 0 && u0 <= R_Q && u1 <= R_Q)
    return (dy * (u0 + u1)) / 2;
  du = u1 - u0;
  num = dy * (h2_32(u1) - h2_32(u0));
  den = 2 * du;
  st->area_div++;
  return num / den;
}

static int cov_alpha32(int32_t total) {
  if (total < 0) total = -total;
  if (total > COV_FULL) total = COV_FULL;
  return (int)((total * 255 + COV_FULL / 2) >> 12);
}

static int floor_div_q(int32_t v) {
  if (v >= 0) return (int)(v / R_Q);
  return -(int)((-v + R_Q - 1) / R_Q);
}

static int ceil_div_q(int32_t v) {
  if (v >= 0) return (int)((v + R_Q - 1) / R_Q);
  return -(int)((-v) / R_Q);
}

static void dirty_mark(int i) {
  if (!g_dirty_flag[i]) {
    g_dirty_flag[i] = 1;
    g_dirty[g_ndirty++] = (uint16_t)i;
  }
}

static void dirty_clear(r_stats *st) {
  for (int k = 0; k < g_ndirty; k++) {
    int i = g_dirty[k];
    g_acc[i] = 0;
    g_suf[i] = 0;
    g_dirty_flag[i] = 0;
  }
  st->memset_bytes += (uint32_t)g_ndirty * 8u;
  g_ndirty = 0;
}

/* Sweep one directed edge over row `row`, clipped to the blend span
 * [span_x0,span_x1).  Returns 1 while the edge is still live next row.
 * Only columns touched are accumulated; the caller clears that dirty set. */
static int edge_row_opt(int32_t ax, int32_t ay, int32_t bx, int32_t by,
                        int row, int span_x0, int span_x1, int16_t *xcache,
                        uint8_t *xvalid, r_stats *st, int32_t *right0) {
  int s, retain;
  int32_t ylo, yhi, xlo, xhi, c0, c1, dy, minx, maxx;
  int K, i0, i1;
  st->edge_calls++;
  if (ay == by) return 0;
  retain = (ay > by ? ay : by) > (int32_t)(row + 1) * R_Q;
  c0 = (int32_t)row * R_Q;
  c1 = c0 + R_Q;
  s = (by > ay) ? 1 : -1;
  if (ay < by) {
    ylo = ay; yhi = by; xlo = ax; xhi = bx;
  } else {
    ylo = by; yhi = ay; xlo = bx; xhi = ax;
  }
  if (ylo >= c1 || yhi <= c0) return retain;
  if (span_x0 >= span_x1) return retain;
  if (ylo < c0) {
    /* The previous row's bottom x IS this row's top x.  Reuse it when the
     * edge was already swept; otherwise interpolate once. */
    xlo = *xvalid ? (int32_t)*xcache : interp_x32(ax, ay, bx, by, c0, st);
    ylo = c0;
  }
  if (yhi > c1) {
    xhi = interp_x32(ax, ay, bx, by, c1, st);
    *xcache = (int16_t)xhi;
    *xvalid = 1;
    yhi = c1;
  }
  if (ylo >= yhi) return retain;
  dy = yhi - ylo;
  if (xlo > xhi) { int32_t tmp = xlo; xlo = xhi; xhi = tmp; }
  minx = xlo;
  maxx = xhi;
  K = ceil_div_q(maxx);
  i0 = floor_div_q(minx);
  if (i0 < 0) i0 = 0;
  i1 = K - 1;
  if (i1 >= R_W) i1 = R_W - 1;
  if (i0 < span_x0) i0 = span_x0;
  if (i1 >= span_x1) i1 = span_x1 - 1;
  /* Interior columns with both ends outside the pixel on the same side have
   * closed forms; a run with u0<0 and u1>64 is a constant-delta arithmetic
   * sequence, seeded with one divide and then stepped without dividing. */
  for (int i = i0; i <= i1; ) {
    int32_t u0 = xlo - (int32_t)i * R_Q;
    int32_t u1 = xhi - (int32_t)i * R_Q;
    int32_t a;
    if (u0 < 0 && u1 > R_Q) {
      int re = floor_div_q(xhi - (R_Q + 1));
      int32_t du = xhi - xlo;
      int32_t den = 2 * du;
      int32_t num = dy * (2 * R_Q * u1 - R_Q * R_Q);
      int32_t q = num / den;
      int32_t r = num - q * den;
      int32_t step = dy * (2 * R_Q * R_Q);
      int32_t stepq = step / den;
      int32_t stepr = step % den;
      st->area_div++;
      if (re > i1) re = i1;
      for (int j = i; j <= re; j++) {
        a = (int32_t)R_Q * dy - q;
        if (a != 0) {
          g_acc[j] += s * a;
          dirty_mark(j);
        }
        q -= stepq;
        if (r < stepr) { q--; r += den - stepr; }
        else r -= stepr;
      }
      i = re + 1;
      continue;
    }
    if (u1 <= 0) a = (int32_t)R_Q * dy;
    else if (u0 >= R_Q) a = 0;
    else if (u0 >= 0 && u1 <= R_Q)
      a = (int32_t)R_Q * dy - (dy * (u0 + u1)) / 2;
    else
      a = (int32_t)R_Q * dy - area_clamped32(u0, u1, dy, st);
    if (a != 0) {
      g_acc[i] += s * a;
      dirty_mark(i);
    }
    i++;
  }
  if (K < 0) K = 0;
  {
    int32_t contrib = s * R_Q * dy;
    if (K < span_x0) *right0 += contrib;
    else if (K < span_x1) {
      g_suf[K] += contrib;
      dirty_mark(K);
    }
  }
  return retain;
}

static void build_fill_buckets(const r_dl *dl, int first, int count,
                               int y0, int y1) {
  for (int y = y0; y < y1; y++) g_row_head[y] = -1;
  for (int e = 0; e < count; e++) {
    int i0 = first + e;
    int i1 = first + ((e + 1) % count);
    int32_t ay = dl->pt[i0][1], by = dl->pt[i1][1];
    int32_t lo = ay < by ? ay : by, hi = ay < by ? by : ay;
    int rs, re;
    if (ay == by) continue;
    rs = floor_div_q(lo);
    re = floor_div_q(hi - 1);
    if (rs < y0) rs = y0;
    if (re >= y1) re = y1 - 1;
    if (rs > re) continue;
    g_xvalid[e] = 0;
    g_edge_next[e] = g_row_head[rs];
    g_row_head[rs] = (int16_t)e;
  }
}

static void build_glow_buckets(const r_dl *dl, int first, int count,
                               int my0, int mh) {
  int32_t oy = (int32_t)my0 * R_Q;
  for (int r = 0; r < mh; r++) g_row_head[r] = -1;
  for (int e = 0; e < count; e++) {
    int i0 = first + e;
    int i1 = first + ((e + 1) % count);
    int32_t ay = dl->pt[i0][1] / 2 - oy;
    int32_t by = dl->pt[i1][1] / 2 - oy;
    int32_t lo = ay < by ? ay : by, hi = ay < by ? by : ay;
    int rs, re;
    if (ay == by) continue;
    rs = floor_div_q(lo);
    re = floor_div_q(hi - 1);
    if (rs < 0) rs = 0;
    if (re >= mh) re = mh - 1;
    if (rs > re) continue;
    g_xvalid[e] = 0;
    g_edge_next[e] = g_row_head[rs];
    g_row_head[rs] = (int16_t)e;
  }
}

static void touch_span(r_rect *t, int x0, int x1, int y) {
  if (!t || x1 <= x0) return;
  if (t->x1 <= t->x0 || t->y1 <= t->y0) {
    t->x0 = (int16_t)x0;
    t->y0 = (int16_t)y;
    t->x1 = (int16_t)x1;
    t->y1 = (int16_t)(y + 1);
    return;
  }
  if (x0 < t->x0) t->x0 = (int16_t)x0;
  if (y < t->y0) t->y0 = (int16_t)y;
  if (x1 > t->x1) t->x1 = (int16_t)x1;
  if (y + 1 > t->y1) t->y1 = (int16_t)(y + 1);
}

/* Render one fill command into the window. */
static void render_fill(const r_dl *dl, const r_cmd *c, r_target *t,
                        r_stats *st, r_rect *touched) {
  int y0 = c->bbox.y0, y1 = c->bbox.y1, xb0 = c->bbox.x0, xb1 = c->bbox.x1;
  int wy0 = clampi(t->win.y0, 0, R_H);
  int wy1 = clampi(t->win.y1, 0, R_H);
  int wx0 = clampi(t->win.x0, 0, R_W);
  int wx1 = clampi(t->win.x1, 0, R_W);
  int first = c->first, count = c->count;
  int nactive = 0;
  r_rgb src = expand565(c->rgb);
  if (y0 < wy0) y0 = wy0;
  if (y1 > wy1) y1 = wy1;
  if (y0 >= y1 || xb0 >= xb1) return;
  st->edges += (uint32_t)count;
  build_fill_buckets(dl, first, count, y0, y1);
  for (int y = y0; y < y1; y++) {
    int hw = g_halfw[y];
    int cx0 = R_CX - hw, cx1 = R_CX + hw;
    int x0 = wx0 > xb0 ? wx0 : xb0;
    int x1 = wx1 < xb1 ? wx1 : xb1;
    int32_t right0 = 0, right;
    int w;
    for (int e = g_row_head[y]; e >= 0; e = g_edge_next[e])
      g_active[nactive++] = (uint16_t)e;
    if (cx0 > x0) x0 = cx0;
    if (cx1 < x1) x1 = cx1;
    if (x0 >= x1) {
      w = 0;
      for (int k = 0; k < nactive; k++) {
        int e = g_active[k];
        int i0 = first + e, i1 = first + ((e + 1) % count);
        int32_t ymax = dl->pt[i0][1] > dl->pt[i1][1]
                           ? dl->pt[i0][1] : dl->pt[i1][1];
        if (ymax > (int32_t)(y + 1) * R_Q) g_active[w++] = (uint16_t)e;
      }
      nactive = w;
      continue;
    }
    st->fill_rows++;
    w = 0;
    for (int k = 0; k < nactive; k++) {
      int e = g_active[k];
      int i0 = first + e, i1 = first + ((e + 1) % count);
      if (edge_row_opt(dl->pt[i0][0], dl->pt[i0][1],
                       dl->pt[i1][0], dl->pt[i1][1], y, x0, x1,
                       &g_xcache[e], &g_xvalid[e], st, &right0))
        g_active[w++] = (uint16_t)e;
    }
    nactive = w;
    right = right0;
    for (int x = x0; x < x1; x++) {
      int cov;
      right += g_suf[x];
      cov = cov_alpha32(g_acc[x] + right);
      if (cov > 0) {
        int a = c->alpha * cov / 255;
        if (a > 0) {
          blend_px(target_px(t, x, y), src, a);
          st->blend_px++;
        }
        st->span_px++;
        if (touched) touch_span(touched, x, x + 1, y);
      }
    }
    dirty_clear(st);
    st->rows++;
  }
}

static void render_mask(const r_cmd *c, int gx, int gy, int gw, int gh,
                        const uint8_t *mask, r_target *t, r_stats *st,
                        r_rect *touched) {
  int wy0 = clampi(t->win.y0, 0, R_H);
  int wy1 = clampi(t->win.y1, 0, R_H);
  int wx0 = clampi(t->win.x0, 0, R_W);
  int wx1 = clampi(t->win.x1, 0, R_W);
  int y0 = gy > wy0 ? gy : wy0;
  int y1 = (gy + gh) < wy1 ? (gy + gh) : wy1;
  r_rgb src = expand565(c->rgb);
  if (y0 < 0) y0 = 0;
  if (y1 > R_H) y1 = R_H;
  for (int y = y0; y < y1; y++) {
    int hw = g_halfw[y];
    int x0 = gx > wx0 ? gx : wx0;
    int x1 = (gx + gw) < wx1 ? (gx + gw) : wx1;
    int cx0 = R_CX - hw, cx1 = R_CX + hw;
    if (x0 < cx0) x0 = cx0;
    if (x1 > cx1) x1 = cx1;
    if (x0 >= x1) continue;
    for (int x = x0; x < x1; x++) {
      int m = mask[(y - gy) * gw + (x - gx)];
      int a;
      if (m <= 0) continue;
      st->span_px++;
      a = m * c->alpha / 255;
      if (a <= 0) continue;
      blend_px(target_px(t, x, y), src, a);
      st->blend_px++;
      if (touched) touch_span(touched, x, x + 1, y);
    }
    st->rows++;
  }
}

/* Half-res coverage for glow.  Coordinates are device Q9.6 / 2, rows are
 * half-res.  The mask covers [mx0,mx0+mw) x [my0,my0+mh) in half-res px. */
static void glow_mask_build(const r_dl *dl, const r_cmd *c, int mx0, int my0,
                            int mw, int mh, r_stats *st) {
  int first = c->first, count = c->count;
  int32_t ox = (int32_t)mx0 * R_Q, oy = (int32_t)my0 * R_Q;
  int nactive = 0;
  build_glow_buckets(dl, first, count, my0, mh);
  for (int r = 0; r < mh; r++) {
    int32_t right0 = 0, right;
    int w = 0;
    for (int e = g_row_head[r]; e >= 0; e = g_edge_next[e])
      g_active[nactive++] = (uint16_t)e;
    st->glow_rows++;
    for (int k = 0; k < nactive; k++) {
      int e = g_active[k];
      int i0 = first + e, i1 = first + ((e + 1) % count);
      if (edge_row_opt(dl->pt[i0][0] / 2 - ox, dl->pt[i0][1] / 2 - oy,
                       dl->pt[i1][0] / 2 - ox, dl->pt[i1][1] / 2 - oy,
                       r, 0, mw, &g_xcache[e], &g_xvalid[e], st, &right0))
        g_active[w++] = (uint16_t)e;
    }
    nactive = w;
    right = right0;
    for (int j = 0; j < mw; j++) {
      int cov;
      right += g_suf[j];
      cov = cov_alpha32(g_acc[j] + right);
      g_glow[r * mw + j] = (uint8_t)cov;
    }
    dirty_clear(st);
  }
}

static void blur_h(int w, int h) {
  for (int y = 0; y < h; y++) {
    uint8_t *row = &g_glow[y * w];
    for (int x = 0; x < w; x++) {
      int l = row[x > 0 ? x - 1 : 0];
      int c = row[x];
      int r = row[x + 1 < w ? x + 1 : w - 1];
      g_grow[x] = (uint8_t)((l + 2 * c + r + 2) / 4);
    }
    memcpy(row, g_grow, (size_t)w);
  }
}

static void blur_v(int w, int h) {
  for (int x = 0; x < w; x++) {
    for (int y = 0; y < h; y++) {
      int u = g_glow[(y > 0 ? y - 1 : 0) * w + x];
      int c = g_glow[y * w + x];
      int d = g_glow[(y + 1 < h ? y + 1 : h - 1) * w + x];
      g_gcol[y] = (uint8_t)((u + 2 * c + d + 2) / 4);
    }
    for (int y = 0; y < h; y++) g_glow[y * w + x] = g_gcol[y];
  }
}

static void render_glow(const r_dl *dl, const r_cmd *c, r_target *t,
                        r_stats *st, r_rect *touched) {
  int mx0, my0, mw, mh;
  int wy0 = clampi(t->win.y0, 0, R_H);
  int wy1 = clampi(t->win.y1, 0, R_H);
  int wx0 = clampi(t->win.x0, 0, R_W);
  int wx1 = clampi(t->win.x1, 0, R_W);
  int bx0 = clampi(c->bbox.x0, 0, R_W);
  int by0 = clampi(c->bbox.y0, 0, R_H);
  int bx1 = clampi(c->bbox.x1, 0, R_W);
  int by1 = clampi(c->bbox.y1, 0, R_H);
  r_rgb src = expand565(c->rgb);
  if (bx0 >= bx1 || by0 >= by1) return;
  mx0 = bx0 / 2;
  my0 = by0 / 2;
  mw = (bx1 + 1) / 2 - mx0;
  mh = (by1 + 1) / 2 - my0;
  if (mw <= 0 || mh <= 0 || mw > R_GLOW_MAX || mh > R_GLOW_MAX) return;
  glow_mask_build(dl, c, mx0, my0, mw, mh, st);
  blur_h(mw, mh);
  blur_v(mw, mh);
  blur_h(mw, mh);
  blur_v(mw, mh);
  if (wy0 < by0) wy0 = by0;
  if (wy1 > by1) wy1 = by1;
  if (wx0 < bx0) wx0 = bx0;
  if (wx1 > bx1) wx1 = bx1;
  for (int y = wy0; y < wy1; y++) {
    int hw = g_halfw[y];
    int x0 = wx0 > (R_CX - hw) ? wx0 : (R_CX - hw);
    int x1 = wx1 < (R_CX + hw) ? wx1 : (R_CX + hw);
    if (x0 >= x1) continue;
    for (int x = x0; x < x1; x++) {
      int gx = x / 2 - mx0;
      int gy = y / 2 - my0;
      int m, a;
      if (gx < 0) gx = 0;
      if (gx >= mw) gx = mw - 1;
      if (gy < 0) gy = 0;
      if (gy >= mh) gy = mh - 1;
      m = g_glow[gy * mw + gx];
      if (m <= 0) continue;
      st->span_px++;
      a = m * c->alpha / 255;
      if (a <= 0) continue;
      blend_px(target_px(t, x, y), src, a);
      st->blend_px++;
      if (touched) touch_span(touched, x, x + 1, y);
    }
    st->rows++;
  }
}

/* ---- public render -------------------------------------------------------- */

void r_clear(r_target *t, uint16_t rgb565) {
  int x0, x1, y0, y1;
  if (!t || !t->px || t->stride <= 0) return;
  if (t->stride < t->win.x1 - t->win.x0) return;
  ensure_lut();
  x0 = clampi(t->win.x0, 0, R_W);
  x1 = clampi(t->win.x1, 0, R_W);
  y0 = clampi(t->win.y0, 0, R_H);
  y1 = clampi(t->win.y1, 0, R_H);
  if (x0 >= x1 || y0 >= y1) return;
  for (int y = y0; y < y1; y++) {
    int hw = g_halfw[y];
    int a = R_CX - hw, b = R_CX + hw;
    uint16_t *dst;
    if (a < x0) a = x0;
    if (b > x1) b = x1;
    if (a >= b) continue;
    dst = &t->px[(y - t->win.y0) * t->stride + (a - t->win.x0)];
    {
      uint16_t v = g_swap_out ? bswap16(rgb565) : rgb565;
      int n = b - a;
      int i = 0;
      /* 32-bit stores when the span is even-aligned: the body clear is ~0.9 ms. */
      if ((a - t->win.x0) & 1) {
        dst[i++] = v;
        n--;
      }
      {
        uint32_t v32 = ((uint32_t)v << 16) | v;
        uint32_t *d32 = (uint32_t *)(dst + i);
        int pairs = n / 2;
        for (int k = 0; k < pairs; k++) d32[k] = v32;
        i += pairs * 2;
      }
      if (i < b - a) dst[i] = v;
    }
  }
}

int r_render(const r_dl *dl, r_target *t, r_stats *st, r_rect *touched) {
  r_stats local;
  if (!dl || !t || !t->px || t->stride <= 0) return R_ERR_PARAM;
  if (t->stride < t->win.x1 - t->win.x0) return R_ERR_PARAM;
  ensure_lut();
  if (!g_lut_ready) return R_ERR_PARAM;
  if (!st) st = &local;
  memset(st, 0, sizeof(*st));
  if (touched) { touched->x0 = touched->y0 = 0; touched->x1 = touched->y1 = 0; }
  for (int i = 0; i < dl->ncmd; i++) {
    const r_cmd *c = &dl->cmd[i];
    if (c->bbox.x1 <= t->win.x0 || c->bbox.x0 >= t->win.x1 ||
        c->bbox.y1 <= t->win.y0 || c->bbox.y0 >= t->win.y1)
      continue;
    if (c->bbox.x1 <= 0 || c->bbox.x0 >= R_W || c->bbox.y1 <= 0 ||
        c->bbox.y0 >= R_H)
      continue;
    st->cmds++;
    switch (c->kind) {
      case R_FILL: render_fill(dl, c, t, st, touched); break;
      case R_GLOW: render_glow(dl, c, t, st, touched); break;
      case R_TEXT:
        for (int g = 0; g < c->count; g++) {
          const r_glyph *gl = &dl->gl[c->first + g];
          int w, h;
          const uint8_t *mask = r_font_mask(c->font, gl->g, &w, &h);
          render_mask(c, gl->x, gl->y, w, h, mask, t, st, touched);
        }
        break;
      case R_SPRITE:
        render_mask(c, c->bbox.x0, c->bbox.y0, c->bbox.x1 - c->bbox.x0,
                    c->bbox.y1 - c->bbox.y0, c->a8, t, st, touched);
        break;
      default: break;
    }
  }
  return R_OK;
}
