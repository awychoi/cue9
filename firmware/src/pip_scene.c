/* pip_scene.c — C port of research/demo/pip.js (544 lines, the behaviour spec).
 *
 * All geometry is scene-local 360x360 (y down), painted inside the 0.9 scene group
 * (pip.js:364) except the rings (screen space, pip.js:253-282).  The raster core
 * supplies area-AA fills, annular sectors, round-join/cap strokes and baked
 * Inter 4-bpp text (renderer/src/font_baked.c); the only vector glyphs added here
 * are retry "U+21BB" and sleep "z" whose size animates: see scene-report.
 *
 * Wave/Easing: targets() = pip.js:288-328; pose easing = pip.js:345-347; blink =
 * pip.js:350-353; typing phase/keys = pip.js:355-358, 521-539.  No RNG outside
 * flying-key spawn; the particle stream is seeded and replay-exact.
 */
#include "pip_scene.h"

#include <math.h>
#include <string.h>

#define PI_F 3.14159265358979323846f
#define TAU_F (2.0f * PI_F)
#define S 0.9f              /* scene scale, pip.js:364 */

/* ---- palette (pip.js:19-23, 29) ------------------------------------------ */
const char *const pip_state_names[PIP_NSTATE] = {
  "work", "idle", "curious", "thinking", "search", "read", "wait", "sleep",
  "wake", "approval", "mcq", "retry", "done", "offline", "hub",
  "workCrazy", "workAnnoyed", "dizzy", "toolCall", "runCmd", "stroked"
};

static const r_rgb C_BG     = { 5, 10, 14 };      /* #050a0e */
static const r_rgb C_CREASE = { 6, 17, 23 };      /* #061117 */
static const r_rgb C_NOTE   = { 16, 28, 36 };     /* #101c24 */
static const r_rgb C_HUB    = { 18, 36, 49 };     /* #122431 */
static const r_rgb C_KEY    = { 8, 20, 27 };      /* #08141b */
static const r_rgb C_SPIRAL = { 16, 35, 44 };     /* #10232c, inside a dissolved eye */
static const r_rgb C_TERM   = { 6, 16, 21 };      /* #061015, command eye frame */
static const r_rgb C_TRACK  = { 115, 140, 124 };
static const r_rgb C_BAT_LO = { 237, 121, 119 };  /* #ed7977 */
static const r_rgb C_BAT_MD = { 231, 194, 101 };  /* #e7c265 */
static const r_rgb C_BAT_HI = { 106, 206, 145 };  /* #6ace91 */
static const r_rgb C_BOLT   = { 247, 215, 116 };  /* #f7d774 */

static const r_rgb PIP_COL[PIP_NSTATE] = {
  { 100, 224, 236 }, /* work      #64e0ec */
  { 144, 223, 209 }, /* idle      #90dfd1 */
  { 189, 164, 245 }, /* curious   #bda4f5 */
  { 152, 183, 243 }, /* thinking  #98b7f3 */
  { 121, 222, 208 }, /* search    #79ded0 */
  { 161, 213, 233 }, /* read      #a1d5e9 */
  { 228, 187, 122 }, /* wait      #e4bb7a */
  { 144, 158, 220 }, /* sleep     #909edc */
  { 242, 209, 143 }, /* wake      #f2d18f */
  { 241, 189, 104 }, /* approval  #f1bd68 */
  { 173, 188, 255 }, /* mcq       #adbcff */
  { 238, 169, 141 }, /* retry     #eea98d */
  { 165, 230, 155 }, /* done      #a5e69b */
  { 147, 165, 177 }, /* offline   #93a5b1 */
  { 241, 183, 128 }, /* hub       #f1b780 */
  { 100, 224, 236 }, /* workCrazy #64e0ec */
  { 100, 224, 236 }, /* workAnnoyed #64e0ec */
  { 230, 168, 245 }, /* dizzy     #e6a8f5 */
  { 122, 216, 245 }, /* toolCall  #7ad8f5 */
  { 126, 240, 181 }, /* runCmd    #7ef0b5 */
  { 255, 158, 199 }  /* stroked   #ff9ec7 */
};

/* pose slots, pip.js:285-286 (sleep is the 14th) */
enum { P_OPEN, P_GX, P_GY, P_ASYM, P_TILT, P_Y, P_POUT, P_O, P_HAPPY,
       P_SQUASH, P_BRIGHT, P_TYPING, P_KEYBOARD, P_SLEEP };

/* ---- small math ----------------------------------------------------------- */
static float clampf1(float x) { return x < 0.f ? 0.f : x > 1.f ? 1.f : x; }
static float mixf(float a, float b, float u) { return a + (b - a) * u; }
static float smf(float x) { x = clampf1(x); return x * x * (3.f - 2.f * x); }
static float pulse(float t, float m, float w) {
  float u = (t - m) / w;
  return expf(-2.f * u * u);   /* pip.js:33 */
}
static float modp(float a, float m) {
  float r = fmodf(a, m);
  return r < 0.f ? r + m : r;
}
static uint8_t A(float a) {
  int v = (int)(a * 255.f + 0.5f);
  return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}
static uint32_t xs32(uint32_t *s) {
  uint32_t x = *s;
  x ^= x << 13; x ^= x >> 17; x ^= x << 5;
  *s = x;
  return x;
}
static float rnd01(uint32_t *s) {
  return (float)(xs32(s) >> 8) * (1.f / 16777216.f);
}

/* The three typing takes share the body and the 5 s loop. */
static bool is_typing_state(int st) {
  return st == PIP_WORK || st == PIP_WORK_CRAZY || st == PIP_WORK_ANNOYED;
}
static float typing_rate(int st) {
  if (st == PIP_WORK_CRAZY) return 4.6f;      /* 23 cycles / 5 s */
  if (st == PIP_WORK_ANNOYED) return 3.6f;    /* 18 cycles / 5 s */
  return 3.2f;                                /* 16 cycles / 5 s */
}
/* The two typing blinks sit well inside the 5 s take.  Keeping the boundary
   open means back-to-back takes, a 5 s REFRESH, and a switch at 5 s never
   produce a blink immediately after the previous take's last one. */
static float work_blink(float u) {
  const float dur = 0.30f;
  float a = modp(u - 3.50f, 5.f);
  float b = modp(u - 1.60f, 5.f);
  float v = 0.f;
  if (a < dur) v = fmaxf(v, sinf(PI_F * a / dur));
  if (b < dur) v = fmaxf(v, sinf(PI_F * b / dur));
  return v;
}

/* ---- primitives ----------------------------------------------------------- */
static void ink(r_dl *dl, r_rgb c, uint8_t a) {
  r_set_color(dl, c);
  r_set_alpha(dl, a);
  r_set_premix(dl, false);
}

static void fill_rrect(r_dl *dl, float x, float y, float w, float h, float r,
                       r_rgb c, uint8_t a) {
  if (a == 0) return;
  ink(dl, c, a);
  r_fill_rrect(dl, x, y, w, h, r);
}
static void fill_ell(r_dl *dl, float cx, float cy, float rx, float ry, r_rgb c,
                     uint8_t a) {
  if (a == 0) return;
  ink(dl, c, a);
  r_fill_ellipse(dl, cx, cy, rx, ry);
}
static void fill_poly(r_dl *dl, const float *p, int n, r_rgb c, uint8_t a) {
  if (a == 0 || n < 3) return;
  ink(dl, c, a);
  r_fill_poly(dl, p, n);
}
static void stroke_path(r_dl *dl, const float *p, int n, float wdev, r_rgb c,
                        uint8_t a, bool closed) {
  if (a == 0 || n < 2) return;
  ink(dl, c, a);
  r_stroke_poly(dl, p, n, wdev, closed);
}
static void stroke_premix(r_dl *dl, const float *p, int n, float wdev, r_rgb c,
                          uint8_t a, bool closed) {
  if (a == 0 || n < 2) return;
  r_set_color(dl, c);
  r_set_alpha(dl, a);
  r_set_premix(dl, true);
  r_stroke_poly(dl, p, n, wdev, closed);
}
static void fill_arc_premix(r_dl *dl, float cx, float cy, float r, float w,
                            float a0, float a1, r_rgb c, uint8_t a) {
  if (a == 0) return;
  r_set_color(dl, c);
  r_set_alpha(dl, a);
  r_set_premix(dl, true);
  r_fill_arc(dl, cx, cy, r, w, a0, a1);
}

/* path builders append points excluding the start point */
static int push_pt(float *p, int n, int cap, float x, float y) {
  if (n >= cap) return n;
  p[2 * n] = x;
  p[2 * n + 1] = y;
  return n + 1;
}
static void path_arc(float *p, int *n, int cap, float cx, float cy, float r,
                     float a0, float a1, int seg) {
  for (int i = 1; i <= seg; i++) {
    float a = a0 + (a1 - a0) * (float)i / (float)seg;
    *n = push_pt(p, *n, cap, cx + r * cosf(a), cy + r * sinf(a));
  }
}
static int arc_stroke_pts(float *p, int cap, float cx, float cy, float r,
                          float a0, float a1, int seg) {
  int n = 1;
  if (cap < 2) return 0;
  p[0] = cx + r * cosf(a0);
  p[1] = cy + r * sinf(a0);
  path_arc(p, &n, cap, cx, cy, r, a0, a1, seg);
  return n;
}
static void path_quad(float *p, int *n, int cap, float x0, float y0, float cx,
                      float cy, float x1, float y1, int seg) {
  for (int i = 1; i <= seg; i++) {
    float u = (float)i / (float)seg, v = 1.f - u;
    *n = push_pt(p, *n, cap,
                 v * v * x0 + 2.f * v * u * cx + u * u * x1,
                 v * v * y0 + 2.f * v * u * cy + u * u * y1);
  }
}
static void path_cubic(float *p, int *n, int cap, float x0, float y0, float c1x,
                       float c1y, float c2x, float c2y, float x1, float y1,
                       int seg) {
  for (int i = 1; i <= seg; i++) {
    float u = (float)i / (float)seg, v = 1.f - u;
    float a = v * v * v, b = 3.f * v * v * u, c = 3.f * v * u * u, d = u * u * u;
    *n = push_pt(p, *n, cap, a * x0 + b * c1x + c * c2x + d * x1,
                 a * y0 + b * c1y + c * c2y + d * y1);
  }
}
/* rounded-rect outline, closed by r_stroke_poly */
static int rrect_path(float *p, int cap, float x, float y, float w, float h,
                      float r) {
  float rr = r;
  int n = 0, seg = 5;
  if (rr < 0.f) rr = 0.f;
  if (rr > 0.5f * (w < h ? w : h)) rr = 0.5f * (w < h ? w : h);
  if (rr < 1e-4f) {
    n = push_pt(p, n, cap, x, y);
    n = push_pt(p, n, cap, x + w, y);
    n = push_pt(p, n, cap, x + w, y + h);
    n = push_pt(p, n, cap, x, y + h);
    return n;
  }
  n = push_pt(p, n, cap, x + rr, y);
  n = push_pt(p, n, cap, x + w - rr, y);
  path_arc(p, &n, cap, x + w - rr, y + rr, rr, -0.5f * PI_F, 0.f, seg);
  n = push_pt(p, n, cap, x + w, y + h - rr);
  path_arc(p, &n, cap, x + w - rr, y + h - rr, rr, 0.f, 0.5f * PI_F, seg);
  n = push_pt(p, n, cap, x + rr, y + h);
  path_arc(p, &n, cap, x + rr, y + h - rr, rr, 0.5f * PI_F, PI_F, seg);
  n = push_pt(p, n, cap, x, y + rr);
  path_arc(p, &n, cap, x + rr, y + rr, rr, PI_F, 1.5f * PI_F, seg);
  return n;
}

/* ---- text ----------------------------------------------------------------- */
/* maxw is logical px (the call site multiplies by the scene scale). */
static float text_c(r_dl *dl, const char *s, float x, float y, int font,
                    float maxw, r_rgb c, uint8_t a) {
  if (!s || !*s || a == 0) return 0.f;
  r_set_color(dl, c);
  r_set_alpha(dl, a);
  r_set_premix(dl, false);
  return r_text(dl, font, s, x, y, R_ALIGN_C, maxw * S);
}

/* params.text: screen space, two lines, baselines 316/328, max 220 px.
 * Split at the last space that fits; a single long token is hard-split. */
static float caption_maxw(float y) {
  float dy = fabsf(y - 180.f);
  float hw = sqrtf(169.f * 169.f - dy * dy) - 6.f;  /* ring inner r169 */
  if (hw > 105.f) hw = 105.f;
  if (hw < 30.f) hw = 30.f;
  return hw * 2.f;
}

static void caption(r_dl *dl, const char *s, r_rgb c, uint8_t a) {
  char buf[64], l1[64], l2[64];
  size_t len, split = 0;
  float w, w1, w2;
  if (!s || !*s || a == 0) return;
  len = strlen(s);
  if (len >= sizeof(buf)) len = sizeof(buf) - 1;
  memcpy(buf, s, len);
  buf[len] = 0;
  r_set_color(dl, c);
  r_set_alpha(dl, a);
  r_set_premix(dl, false);
  w1 = caption_maxw(316.f);
  w2 = caption_maxw(328.f);
  w = r_text_width(dl, R_FONT_10, buf);
  if (w <= w1) {
    r_text_baseline(dl, R_FONT_10, buf, 180.f, 316.f, R_ALIGN_C, w1);
    return;
  }
  for (size_t i = 0; i < len; i++) {
    if (buf[i] != ' ') continue;
    buf[i] = 0;
    if (r_text_width(dl, R_FONT_10, buf) <= w1) split = i;
    buf[i] = ' ';
  }
  if (split == 0) {
    size_t fit = len;
    while (fit > 0) {
      memcpy(l1, buf, fit);
      l1[fit] = 0;
      if (r_text_width(dl, R_FONT_10, l1) <= w1) break;
      fit--;
    }
    split = fit;
  }
  memcpy(l1, buf, split);
  l1[split] = 0;
  {
    const char *rest = buf + split;
    while (*rest == ' ') rest++;
    memcpy(l2, rest, strlen(rest) + 1);
  }
  r_text_baseline(dl, R_FONT_10, l1, 180.f, 316.f, R_ALIGN_C, w1);
  if (l2[0])
    r_text_baseline(dl, R_FONT_10, l2, 180.f, 328.f, R_ALIGN_C, w2);
}

/* ---- face parts ----------------------------------------------------------- */
static void arch_eye(r_dl *dl, float x, float y, float w, r_rgb c, float lift,
                     float weight, uint8_t a) {
  float p[2 * 24];
  int n = 1;
  p[0] = x - w * 0.5f;
  p[1] = y + lift;
  path_quad(p, &n, 24, p[0], p[1], x, y - lift - 4.f, x + w * 0.5f, y + lift, 14);
  r_set_glow(dl, 2.5f);   /* pip.js face shadowBlur 5 */
  stroke_path(dl, p, n, weight * S, c, a, false);
  r_set_glow(dl, 0.f);
}

/* annoyed eye: the lower half of the 42x eh pill, flat at the centre line.
   The C raster has no clip, so build the flat-top round-bottom outline. */
static void half_lid(r_dl *dl, float x, float y, float eh, r_rgb c, uint8_t a) {
  float p[2 * 64];
  int n = 0;
  float h = eh * 0.5f;
  float r = fminf(20.f, h);
  n = push_pt(p, n, 64, x - 21.f, y);
  n = push_pt(p, n, 64, x + 21.f, y);
  n = push_pt(p, n, 64, x + 21.f, y + h - r);
  path_quad(p, &n, 64, x + 21.f, y + h - r, x + 21.f, y + h, x, y + h, 10);
  path_quad(p, &n, 64, x, y + h, x - 21.f, y + h, x - 21.f, y + h - r, 10);
  n = push_pt(p, n, 64, x - 21.f, y);
  fill_poly(dl, p, n, c, a);
}

/* tongue, mouth-local (pip.js:124-140; pip_2's 13 px crazy blep) */
static void tongue(r_dl *dl, float tx, float ty, int side, r_rgb c, uint8_t a,
                   int long_tongue) {
  float p[2 * 32];
  int n = 0;
  const float r = 5.5f;   /* cfg.tongueSize; was 7 (ref is ~5.5) */
  float bx = tx + side * (long_tongue ? 8.f : 3.f), by = ty + 3.f;
  float tl = long_tongue ? 13.f : 5.f;
  n = push_pt(p, n, 32, bx - r, by - 1.f);
  n = push_pt(p, n, 32, bx + r, by - 1.f);
  n = push_pt(p, n, 32, bx + r, by + tl);
  path_arc(p, &n, 32, bx, by + tl, r, 0.f, PI_F, 8);
  r_set_glow(dl, 0.8f);   /* pip.js tongue shadowBlur 1.6 */
  fill_poly(dl, p, n, c, a);
  r_set_glow(dl, 0.f);
  n = 0;
  n = push_pt(p, n, 32, bx - r - 1.f, by - 4.f);
  n = push_pt(p, n, 32, bx + r + 1.f, by - 4.f);
  n = push_pt(p, n, 32, bx + r + 1.f, by);
  path_quad(p, &n, 32, bx + r + 1.f, by, bx, by + 3.5f, bx - r - 1.f, by, 8);
  fill_poly(dl, p, n, C_BG, a);
}

/* mouth at (x,y) = (180,190), pip.js:84-121 */
static void mouth(r_dl *dl, float x, float y, r_rgb c, float pout, float o,
                  int hub, int blep, int side, int long_blep, uint8_t a) {
  float p[2 * 96];
  int n;

  if (blep) {
    tongue(dl, x, y, side, c, a, long_blep);
    n = 0;
    n = push_pt(p, n, 96, x - 13.f, y - 1.f);
    path_quad(p, &n, 96, x - 13.f, y - 1.f, x - 6.f, y + 7.f, x, y + 3.f, 8);
    path_quad(p, &n, 96, x, y + 3.f, x + 6.f, y + 7.f, x + 13.f, y - 1.f, 8);
    r_set_glow(dl, 2.5f);
    stroke_path(dl, p, n, 3.4f * S, c, a, false);
    r_set_glow(dl, 0.f);
    return;
  }
  if (hub) {
    r_set_glow(dl, 2.5f);
    fill_ell(dl, x, y + 3.f, 4.3f, 6.1f, c, a);
    r_set_glow(dl, 0.f);
    fill_ell(dl, x, y + 2.4f, 2.3f, 3.8f, C_BG, a);
    return;
  }
  if (pout > 0.5f) {
    n = 0;
    n = push_pt(p, n, 96, x - 13.f, y + 13.f);
    path_quad(p, &n, 96, x - 13.f, y + 13.f, x, y + 3.f, x + 13.f, y + 13.f, 10);
    r_set_glow(dl, 2.5f);
    stroke_path(dl, p, n, 3.4f * S, c, a, false);
    r_set_glow(dl, 0.f);
    return;
  }
  if (o > 0.4f) {
    r_set_glow(dl, 2.5f);
    fill_ell(dl, x, y + 4.f, 4.f + o * 3.f, 6.f + o * 5.f, c, a);
    r_set_glow(dl, 0.f);
    fill_ell(dl, x, y + 3.f, 2.f + o, 3.f + o * 4.f, C_BG, a);
    return;
  }
  /* two rounded lobes meeting at a small peak */
  n = 0;
  n = push_pt(p, n, 96, x - 16.f, y - 3.f);
  path_quad(p, &n, 96, x - 16.f, y - 3.f, x - 13.f, y + 9.f, x - 8.f, y + 9.f, 7);
  path_quad(p, &n, 96, x - 8.f, y + 9.f, x - 3.f, y + 9.f, x, y - 1.f, 7);
  path_quad(p, &n, 96, x, y - 1.f, x + 3.f, y + 9.f, x + 8.f, y + 9.f, 7);
  path_quad(p, &n, 96, x + 8.f, y + 9.f, x + 13.f, y + 9.f, x + 16.f, y - 3.f, 7);
  r_set_glow(dl, 2.5f);
  stroke_path(dl, p, n, 3.f * S, c, a, false);
  r_set_glow(dl, 0.f);
}

/* paw (pip.js:68-80); caller has scene CTM live */
static void paw(r_dl *dl, float x, float y, int side, float lift, r_rgb c,
                float alpha, float size) {
  uint8_t a = A(alpha);
  float sx = (1.23f - 0.4f * lift) * size;
  float sy = (0.62f + 0.6f * lift) * size;
  float p[4];
  if (a == 0) return;
  r_push(dl);
  r_translate(dl, x, y);
  r_rotate(dl, side * (-0.15f + 0.43f * lift));
  r_scale(dl, sx, sy);
  r_set_glow(dl, 2.0f);   /* shadowBlur 4 -> sigma 2 */
  fill_rrect(dl, -23.f, -25.f, 46.f, 50.f, 19.f, c, a);
  r_set_glow(dl, 0.f);
  for (int j = -1; j <= 1; j++) {
    p[0] = (float)j * 9.f; p[1] = -14.f;
    p[2] = (float)j * 9.f; p[3] = -5.f;
    stroke_path(dl, p, 2, 2.2f * S, C_CREASE, a, false);
  }
  r_pop(dl);
}

/* keyboard (pip.js:160-172) */
static void keyboard(r_dl *dl, float y, r_rgb c, float alpha,
                     const bool press[3][11], float tilt,
                     int agents, const r_rgb *agent_col) {
  float p[2 * 40];
  int n;
  if (alpha <= 0.01f) return;
  r_push(dl);
  r_translate(dl, 180.f, y);
  r_rotate(dl, tilt);
  fill_rrect(dl, -106.f, -8.f, 212.f, 45.f, 10.f, c, A(0.065f * alpha));
  n = rrect_path(p, 40, -106.f, -8.f, 212.f, 45.f, 10.f);
  stroke_path(dl, p, n, 1.f * S, c, A(0.78f * alpha), true);
  /* Six keys per row, not the original eleven. The cat is above the keyboard,
   * so the spacebar is at the top edge and the key rows run away from it.
   * Agents fill column-major (all three keys of a column before the next),
   * then the spacebar is slot 18. The six colours are the HTML job palette. */
  if (agents > 19) agents = 19;
  for (int r = 0; r < 3; r++) {
    for (int j = 0; j < 6; j++) {
      int on = press[r][j * 2];
      int slot = j * 3 + r;
      r_rgb kc = c;
      float ka = on ? 0.95f : 0.38f;
      if (slot < agents) {
        kc = agent_col[slot % 6];
        ka = on ? 0.95f : 0.85f;
      }
      fill_rrect(dl, -92.f + (float)j * 32.f,
                 2.f + (float)r * 10.f + (on ? 2.5f : 0.f), 24.f, 6.f, 2.f, kc,
                 A(ka * alpha));
    }
  }
  {
    r_rgb sc = c;
    float sa = 0.55f;
    if (agents > 18) { sc = agent_col[18 % 6]; sa = 0.85f; }
    fill_rrect(dl, -37.f, -6.f, 74.f, 5.f, 2.f, sc, A(sa * alpha));
  }
  r_pop(dl);
}

/* wifi arcs, face-local (pip.js:174-186) */
static void wifi(r_dl *dl, float x, float y, float t, r_rgb c, float period,
                 float scale, uint8_t outer) {
  float p[2 * 32];
  int n;
  float u, fo = (float)outer / 255.f;
  r_push(dl);
  r_translate(dl, x, y);
  r_scale(dl, scale, scale);
  fill_ell(dl, 0.f, 0.f, 2.2f, 2.2f, c, outer);
  u = modp(t, period) / period;
  for (int i = 0; i < 3; i++) {
    float build = smf((u - (float)i * 0.10f) / 0.16f);
    float fade = 1.f - smf((u - 0.72f) / 0.28f);
    float a = 0.12f + 0.83f * build * fade;
    n = arc_stroke_pts(p, 32, 0.f, 0.f, 10.f + (float)i * 9.f,
                       1.2f * PI_F, 1.8f * PI_F, 14);
    stroke_path(dl, p, n, 3.f * scale * S, c, A(fo * a), false);
  }
  r_pop(dl);
}

/* drool (pip.js:206-227), face-local */
static void drool(r_dl *dl, float x, float y, float t, r_rgb c, uint8_t outer) {
  const float period = 6.f, max = 29.f;
  float u = modp(t, period) / period;
  float reach = max * smf(u / 0.74f);
  float fo = (float)outer / 255.f;
  if (u < 0.81f) {
    float len = u < 0.74f ? reach : reach * (1.f - smf((u - 0.74f) / 0.07f));
    if (len > 0.25f) {
      float p[2 * 48];
      int n = 0;
      n = push_pt(p, n, 48, x - 1.8f, y - 1.f);
      path_cubic(p, &n, 48, x - 1.8f, y - 1.f, x - 1.f, y + len * 0.4f,
                 x - 1.5f, y + len * 0.7f, x - 3.7f, y + len, 10);
      path_cubic(p, &n, 48, x - 3.7f, y + len, x - 6.f, y + len + 7.f,
                 x + 6.f, y + len + 7.f, x + 3.7f, y + len, 10);
      path_cubic(p, &n, 48, x + 3.7f, y + len, x + 1.5f, y + len * 0.7f,
                 x + 1.f, y + len * 0.4f, x + 1.8f, y - 1.f, 10);
      fill_poly(dl, p, n, c, A(0.72f * fo));
    }
  }
  if (u >= 0.74f && u < 0.95f) {
    float fall = (u - 0.74f) / 0.21f;
    fill_ell(dl, x, y + max + fall * fall * 38.f, 3.5f, 5.f, c,
             A(1.f - smf(fall)));
  }
}

/* ---- props ---------------------------------------------------------------- */
static void toy_mouse(r_dl *dl, float x, float y, int dir, r_rgb c, float wob) {
  float p[6];
  r_push(dl);
  r_translate(dl, x, y);
  r_scale(dl, (float)dir, 1.f);
  fill_ell(dl, 0.f, 0.f, 13.f, 8.f, c, A(0.9f));
  fill_ell(dl, 9.f, -2.f, 5.f, 4.5f, c, A(0.9f));
  fill_ell(dl, 11.f, -5.f, 3.f, 2.6f, c, A(0.9f));
  p[0] = -12.f; p[1] = 0.f;
  p[2] = -22.f; p[3] = -6.f + wob * 4.f;
  p[4] = -26.f; p[5] = 2.f - wob * 3.f;
  stroke_path(dl, p, 3, 2.f * S, c, A(0.72f), false);
  r_pop(dl);
}

static void note(r_dl *dl, float x, float y, float ang, r_rgb c, uint8_t a) {
  float p[4];
  r_push(dl);
  r_translate(dl, x, y);
  r_rotate(dl, ang);
  fill_rrect(dl, -21.f, -28.f, 42.f, 56.f, 5.f, C_NOTE, a);
  { /* 1 px outline */
    float q[2 * 40];
    int n = rrect_path(q, 40, -21.f, -28.f, 42.f, 56.f, 5.f);
    stroke_path(dl, q, n, 1.f * S, c, a, true);
  }
  fill_rrect(dl, -20.f, -27.f, 40.f, 7.f, 3.f, c, a);
  for (int i = 0; i < 4; i++) {
    p[0] = -13.f; p[1] = -7.f + (float)i * 8.f;
    p[2] = i % 2 ? 6.f : 13.f; p[3] = p[1];
    stroke_path(dl, p, 2, 1.5f * S, c, A(0.6f * a / 255.f), false);
  }
  r_pop(dl);
}

/* retry "U+21BB" refresh arrow, vector fallback for the missing font glyph */
static void mark_refresh(r_dl *dl, float cx, float cy, r_rgb c, uint8_t a) {
  float p[2 * 40];
  float r = 7.5f, a0 = 0.15f * PI_F, a1 = 1.75f * PI_F;
  int n = arc_stroke_pts(p, 40, cx, cy, r, a0, a1, 22);
  float tx = cx - r * sinf(a1), ty = cy + r * cosf(a1);
  float nx = cosf(a1), ny = sinf(a1);
  float tip[2], base[2], tri[6];
  float inv = 1.f / sqrtf(tx * tx + ty * ty);
  tx *= inv; ty *= inv;
  tip[0] = cx + r * cosf(a1) + tx * 4.6f;
  tip[1] = cy + r * sinf(a1) + ty * 4.6f;
  base[0] = cx + r * cosf(a1) - tx * 2.6f;
  base[1] = cy + r * sinf(a1) - ty * 2.6f;
  tri[0] = tip[0]; tri[1] = tip[1];
  tri[2] = base[0] + nx * 4.2f; tri[3] = base[1] + ny * 4.2f;
  tri[4] = base[0] - nx * 4.2f; tri[5] = base[1] - ny * 4.2f;
  stroke_path(dl, p, n, 2.2f * S, c, a, false);
  fill_poly(dl, tri, 3, c, a);
}

/* sleep "z": animated size the 4 fixed font sizes cannot express (pip.js:513-518) */
static void z_mark(r_dl *dl, float x, float y, float size, r_rgb c, uint8_t a) {
  float hw = size * 0.34f, hh = size * 0.36f;
  float p[8];
  p[0] = x - hw; p[1] = y - hh;
  p[2] = x + hw; p[3] = y - hh;
  p[4] = x - hw; p[5] = y + hh;
  p[6] = x + hw; p[7] = y + hh;
  stroke_path(dl, p, 4, (size * 0.11f < 1.2f ? 1.2f : size * 0.11f) * S, c, a,
              false);
}

/* hub keyboard glyph (pip.js:230-250) */
static void hub_glyph(r_dl *dl, float t, r_rgb c) {
  const float period = 1.8f;
  float u = modp(t, period) / period;
  float a = 1.f;
  uint8_t ai;
  float p[4], q[2 * 40];
  int n;
  if (u >= 0.22f && u < 0.48f) a = 1.f - smf((u - 0.22f) / 0.26f);
  else if (u >= 0.48f && u < 0.72f) a = 0.f;
  else if (u >= 0.72f) a = smf((u - 0.72f) / 0.28f);
  ai = A(a);
  r_push(dl);
  r_translate(dl, 180.f, 250.f);
  fill_rrect(dl, -41.f, -28.f, 82.f, 53.f, 12.f, C_HUB, ai);
  n = rrect_path(q, 40, -41.f, -28.f, 82.f, 53.f, 12.f);
  stroke_path(dl, q, n, 1.f * S, c, ai, true);
  fill_rrect(dl, -38.f, -25.f, 76.f, 15.f, 9.f, c, A(0.17f * a));
  for (int i = 0; i < 3; i++) {
    fill_rrect(dl, -29.f + (float)i * 20.f, 8.f, 16.f, 10.f, 2.f, C_BG, ai);
    n = rrect_path(q, 40, -29.f + (float)i * 20.f, 8.f, 16.f, 10.f, 2.f);
    stroke_path(dl, q, n, 1.f * S, c, A(0.85f * a), true);
  }
  p[0] = -24.f; p[1] = -28.f; p[2] = -24.f; p[3] = -44.f;
  stroke_path(dl, p, 2, 3.f * S, c, ai, false);
  fill_ell(dl, -24.f, -45.f, 2.3f, 2.3f, c, ai);
  p[0] = 25.f; p[1] = -28.f; p[2] = 25.f; p[3] = -39.f;
  stroke_path(dl, p, 2, 3.f * S, c, A(0.8f * a), false);
  fill_ell(dl, 25.f, -40.f, 2.f, 2.f, c, ai);
  r_pop(dl);
}

/* ---- dizzy / tool / command props ----------------------------------------- */
/* 8-point star: 4 long points, 4 short, filling instead of a canvas glyph. */
static void star_mark(r_dl *dl, float x, float y, float rad, float rot, r_rgb c,
                      uint8_t a) {
  float p[16];
  for (int i = 0; i < 8; i++) {
    float aa = (float)i * (PI_F * 0.25f) + rot;
    float rr = (i & 1) ? rad * 0.4f : rad;
    p[2 * i] = x + cosf(aa) * rr;
    p[2 * i + 1] = y + sinf(aa) * rr;
  }
  fill_poly(dl, p, 8, c, a);
}

/* Dizzy eye: the eye pill with a dark spiral winding in from its edge. The
 * spiral radius stays inside the pill, so the raster needs no clip. */
static void spiral_eye(r_dl *dl, float x, float y, float w, float eh, float t,
                       r_rgb c, uint8_t a) {
  float rx = w * 0.7f, ry = eh * 0.48f;
  float p[2 * 96];
  int n = 0;
  float rr = fminf(rx, ry) * 0.8f;
  if (a == 0) return;
  r_set_glow(dl, 2.5f);
  fill_ell(dl, x, y, rx, ry, c, a);
  r_set_glow(dl, 0.f);
  for (int i = 0; i < 44; i++) {
    float ang = (float)i * 0.36f + t * 0.8f;
    float rad = (float)i / 44.f * rr;
    n = push_pt(p, n, 96, x + cosf(ang) * rad, y + sinf(ang) * rad);
  }
  stroke_path(dl, p, n, 3.f * S, C_SPIRAL, a, false);
}

/* Command-line eye: a mini terminal where the eye was. No clip primitive, so
 * rows are skipped near the frame's rounded top/bottom and their length is
 * clamped to the frame's horizontal inset at that height. */
static void cmd_eye(r_dl *dl, float x, float y, float w, float h, int side,
                    float t, r_rgb c, uint8_t a) {
  float bw = fmaxf(44.f, w * 1.12f), bh = fmaxf(44.f, h * 0.95f);
  float rad = fminf(10.f, fminf(bw, bh) * 0.24f);
  float speed = 3.2f, frac, x0, right;
  float tt = t * speed + (side < 0 ? 0.f : 3.f);
  int step = (int)floorf(tt), rows;
  if (a == 0) return;
  frac = modp(tt, 1.f);
  r_push(dl);
  r_translate(dl, x, y);
  fill_rrect(dl, -bw * 0.5f, -bh * 0.5f, bw, bh, rad, C_TERM, a);
  {
    float p[2 * 40];
    int n = rrect_path(p, 40, -bw * 0.5f, -bh * 0.5f, bw, bh, rad);
    stroke_path(dl, p, n, 2.f * S, c, a, true);
  }
  x0 = -bw * 0.5f + 7.f;
  right = bw * 0.5f - 6.f;
  rows = (int)ceilf(bh / 9.f) + 1;
  for (int i = 0; i < rows; i++) {
    int idx = step + i;
    float ly = -bh * 0.5f + 9.f + (float)i * 9.f - frac * 9.f;
    float edge = fminf(ly + bh * 0.5f, bh * 0.5f - ly);
    float inset = 0.f, len, p[8];
    if (ly < -bh * 0.5f + 5.f || ly > bh * 0.5f - 5.f) continue;
    if (edge < rad) {
      float d = rad - edge;
      inset = rad - sqrtf(fmaxf(0.f, rad * rad - d * d));
    }
    if (idx & 1) {
      float sx = x0 + inset + 4.f;
      len = 12.f + (float)((idx * 43 + (side < 0 ? 11 : 5)) % (int)(bw - 20.f));
      if (len > right - sx) len = right - sx;
      if (len < 3.f) continue;
      p[0] = sx; p[1] = ly; p[2] = sx + len; p[3] = ly;
      stroke_path(dl, p, 2, 1.9f * S, c, A(0.52f * a / 255.f), false);
    } else {
      float sx = x0 + inset;
      len = 10.f + (float)((idx * 29 + (side < 0 ? 7 : 19)) % (int)(bw - 24.f));
      if (len > right - sx - 7.f) len = right - sx - 7.f;
      if (len < 4.f) continue;
      p[0] = sx; p[1] = ly - 2.2f; p[2] = sx + 3.5f; p[3] = ly;
      p[4] = sx; p[5] = ly + 2.2f;
      stroke_path(dl, p, 3, 1.7f * S, c, a, false);
      p[0] = sx + 7.f; p[1] = ly; p[2] = sx + 7.f + len; p[3] = ly;
      stroke_path(dl, p, 2, 2.2f * S, c, A(0.95f * a / 255.f), false);
    }
  }
  if (((int)floorf(t * 3.6f + (side < 0 ? 0.f : 0.5f))) % 2 == 0)
    fill_rrect(dl, -bw * 0.5f + 8.f, bh * 0.5f - 13.f, 4.5f, 7.5f, 1.f, c, a);
  r_pop(dl);
}

static void bolt_mark(r_dl *dl, float x, float y, float rot, r_rgb c) {
  float p[12];
  for (int i = 0; i < 6; i++) {
    float aa = (float)i * TAU_F / 6.f + rot;
    p[2 * i] = x + cosf(aa) * 13.f;
    p[2 * i + 1] = y + sinf(aa) * 13.f;
  }
  fill_poly(dl, p, 6, c, A(0.18f));
  stroke_path(dl, p, 6, 2.2f * S, c, 255, true);
  ink(dl, c, 255);
  r_fill_arc(dl, x, y, 5.f, 1.2f, 0.f, TAU_F);
}

static void wrench_prop(r_dl *dl, float x, float y, float ang, r_rgb c) {
  float p[2 * 40];
  int n = 0;
  r_push(dl);
  r_translate(dl, x, y);
  r_rotate(dl, ang);
  fill_rrect(dl, -5.f, -4.f, 52.f, 8.f, 3.f, c, A(0.22f));
  {
    float q[2 * 40];
    int m = rrect_path(q, 40, -5.f, -4.f, 52.f, 8.f, 3.f);
    stroke_path(dl, q, m, 1.6f * S, c, 255, true);
  }
  n = push_pt(p, n, 40, -8.f + 12.f * cosf(0.55f), 12.f * sinf(0.55f));
  path_arc(p, &n, 40, -8.f, 0.f, 12.f, 0.55f, TAU_F - 0.55f, 18);
  n = push_pt(p, n, 40, -4.f, -5.f);
  n = push_pt(p, n, 40, -4.f, 5.f);
  fill_poly(dl, p, n, c, A(0.25f));
  stroke_path(dl, p, n, 2.f * S, c, 255, true);
  fill_ell(dl, 45.f, 0.f, 4.f, 4.f, c, 255);
  r_pop(dl);
}

static void hammer_prop(r_dl *dl, float x, float y, float ang, r_rgb c) {
  float p[6];
  r_push(dl);
  r_translate(dl, x, y);
  r_rotate(dl, ang);
  fill_rrect(dl, -4.f, -42.f, 8.f, 48.f, 3.f, c, A(0.22f));
  {
    float q[2 * 40];
    int m = rrect_path(q, 40, -4.f, -42.f, 8.f, 48.f, 3.f);
    stroke_path(dl, q, m, 1.6f * S, c, 255, true);
    m = rrect_path(q, 40, -18.f, -54.f, 36.f, 15.f, 4.f);
    fill_rrect(dl, -18.f, -54.f, 36.f, 15.f, 4.f, c, A(0.32f));
    stroke_path(dl, q, m, 1.6f * S, c, 255, true);
  }
  p[0] = 18.f; p[1] = -51.f; p[2] = 24.f; p[3] = -47.f; p[4] = 18.f; p[5] = -42.f;
  stroke_path(dl, p, 3, 2.4f * S, c, 255, false);
  r_pop(dl);
}

static void tool_props(r_dl *dl, float t, r_rgb c, int variant) {
  if (variant % 2 == 0) {
    float crank = sinf(t * 4.5f);
    float bolt_rot = floorf(t * 4.5f / TAU_F) * 1.1f + fmaxf(0.f, crank) * 0.65f;
    float w_ang = -0.35f + crank * 0.45f;
    float px, py;
    r_push(dl);
    r_translate(dl, 180.f, 247.f);
    fill_rrect(dl, -48.f, -17.f, 96.f, 34.f, 9.f, c, A(0.08f));
    {
      float q[2 * 40];
      int n = rrect_path(q, 40, -48.f, -17.f, 96.f, 34.f, 9.f);
      stroke_path(dl, q, n, 1.6f * S, c, A(0.65f), true);
    }
    bolt_mark(dl, -13.f, 0.f, bolt_rot, c);
    r_pop(dl);
    wrench_prop(dl, 171.f, 247.f, w_ang, c);
    px = 171.f + cosf(w_ang) * 45.f;
    py = 247.f + sinf(w_ang) * 45.f;
    paw(dl, 112.f, 262.f, -1, 0.32f, c, 1.f, 0.92f);
    paw(dl, px + 8.f, py + 8.f, 1, 0.42f, c, 1.f, 0.92f);
    if (crank > 0.72f) {
      for (int i = 0; i < 3; i++) {
        float aa = -1.6f + (float)i * 0.65f;
        float p[4];
        p[0] = 166.f + cosf(aa) * 18.f; p[1] = 247.f + sinf(aa) * 18.f;
        p[2] = 166.f + cosf(aa) * 28.f; p[3] = 247.f + sinf(aa) * 28.f;
        stroke_path(dl, p, 2, 2.f * S, c, 255, false);
      }
    }
  } else {
    float cycle = modp(t * 2.4f, 1.f);
    float swing = cycle < 0.35f ? mixf(0.3f, -1.15f, smf(cycle / 0.35f))
                  : cycle < 0.5f ? mixf(-1.15f, 0.22f, smf((cycle - 0.35f) / 0.15f))
                                 : mixf(0.22f, 0.3f, smf((cycle - 0.5f) / 0.5f));
    int hit = cycle >= 0.47f && cycle < 0.68f;
    r_push(dl);
    r_translate(dl, 180.f, 257.f);
    fill_rrect(dl, -38.f, -11.f, 76.f, 22.f, 5.f, c, A(0.16f));
    {
      float q[2 * 40];
      int n = rrect_path(q, 40, -38.f, -11.f, 76.f, 22.f, 5.f);
      stroke_path(dl, q, n, 1.6f * S, c, 255, true);
    }
    fill_rrect(dl, -7.f, -23.f, 14.f, 12.f, 2.f, c, A(0.3f));
    {
      float q[2 * 40];
      int n = rrect_path(q, 40, -7.f, -23.f, 14.f, 12.f, 2.f);
      stroke_path(dl, q, n, 1.4f * S, c, 255, true);
    }
    r_pop(dl);
    hammer_prop(dl, 232.f, 248.f, swing, c);
    paw(dl, 120.f, 266.f, -1, 0.3f, c, 1.f, 0.92f);
    paw(dl, 232.f + sinf(swing) * 10.f, 248.f + cosf(swing) * 6.f, 1, 0.45f,
        c, 1.f, 0.92f);
    if (hit) {
      float u = (cycle - 0.47f) / 0.21f;
      for (int i = 0; i < 5; i++) {
        float aa = -PI_F * 0.15f - (float)i * (PI_F * 0.7f / 4.f);
        float d = 12.f + u * 24.f;
        float p[4];
        p[0] = 180.f + cosf(aa) * d * 0.6f;
        p[1] = 233.f + sinf(aa) * d * 0.6f;
        p[2] = 180.f + cosf(aa) * d;
        p[3] = 233.f + sinf(aa) * d;
        stroke_path(dl, p, 2, 2.2f * S, c, A(1.f - u), false);
      }
    }
  }
  text_c(dl, "FIXING", 180.f, 302.f, R_FONT_14, 110.f, c, A(0.75f));
}

static void run_cmd_props(r_dl *dl, float t, r_rgb c) {
  float tl = fmaxf(0.f, sinf(t * 7.5f)) * 0.22f;
  float tr = fmaxf(0.f, sinf(t * 7.5f + PI_F)) * 0.22f;
  paw(dl, 124.f, 260.f - tl * 8.f, -1, 0.32f + tl, c, 1.f, 1.f);
  paw(dl, 236.f, 260.f - tr * 8.f, 1, 0.32f + tr, c, 1.f, 1.f);
  text_c(dl, "EXEC", 180.f, 276.f, R_FONT_10, 90.f, c, A(0.72f));
}

static void dizzy_props(r_dl *dl, float t, r_rgb c) {
  float wobble = sinf(t * 5.5f) * 0.12f;
  for (int i = 0; i < 3; i++) {
    float ang = t * 3.2f + (float)i * (TAU_F / 3.f);
    float sx = 180.f + cosf(ang) * 68.f;
    float sy = 60.f + sinf(ang) * 13.f;
    float sc = 0.75f + 0.35f * sinf(ang);
    star_mark(dl, sx, sy, 7.5f * sc, t * 4.f + (float)i, c, A(0.85f));
  }
  text_c(dl, "@", 296.f + sinf(t * 4.f) * 3.f, 84.f + cosf(t * 4.f) * 3.f,
         R_FONT_18, 30.f, c, A(0.85f));
  paw(dl, 122.f + sinf(t * 6.f) * 6.f, 254.f + cosf(t * 6.f) * 4.f, -1,
      0.35f + wobble, c, 1.f, 1.f);
  paw(dl, 238.f - sinf(t * 6.f) * 6.f, 254.f - cosf(t * 6.f) * 4.f, 1,
      0.35f - wobble, c, 1.f, 1.f);
}

/* small heart, local path from the prototype, scaled around (x,y) */
static void heart_mark(r_dl *dl, float x, float y, float s, r_rgb c, float alpha) {
  float p[2 * 40];
  int n = 1;
  p[0] = x;
  p[1] = y + 5.f * s;
  path_cubic(p, &n, 40, x, y + 5.f * s, x - 9.f * s, y - 2.f * s,
             x - 10.f * s, y - 11.f * s, x - 4.f * s, y - 11.f * s, 6);
  path_cubic(p, &n, 40, x - 4.f * s, y - 11.f * s, x - 1.f * s, y - 11.f * s,
             x, y - 8.f * s, x, y - 6.f * s, 6);
  path_cubic(p, &n, 40, x, y - 6.f * s, x, y - 8.f * s, x + 1.f * s,
             y - 11.f * s, x + 4.f * s, y - 11.f * s, 6);
  path_cubic(p, &n, 40, x + 4.f * s, y - 11.f * s, x + 10.f * s, y - 11.f * s,
             x + 9.f * s, y - 2.f * s, x, y + 5.f * s, 6);
  fill_poly(dl, p, n, c, A(alpha));
}

/* Happy (stroked): blush, floating hearts, kneading paws and a purr label. */
static void stroked_props(r_dl *dl, float t, r_rgb c, int effects) {
  float knL = sinf(t * 5.2f) * 0.5f + 0.5f;
  float knR = sinf(t * 5.2f + PI_F) * 0.5f + 0.5f;
  fill_ell(dl, 104.f, 174.f, 16.f, 8.f, c, A(0.38f));
  fill_ell(dl, 256.f, 174.f, 16.f, 8.f, c, A(0.38f));
  if (effects) {
    for (int i = 0; i < 3; i++) {
      float u = modp(t * 0.55f + (float)i * 0.33f, 1.f);
      float hx = 180.f + ((float)i - 1.f) * 58.f + sinf(t * 3.f + (float)i * 2.f) * 10.f;
      float hy = 122.f - u * 62.f;
      heart_mark(dl, hx, hy, 0.75f + u * 0.4f, c, sinf(u * PI_F) * 0.9f);
    }
  }
  paw(dl, 126.f, 258.f - knL * 10.f, -1, 0.35f + knL * 0.2f, c, 1.f, 1.f);
  paw(dl, 234.f, 258.f - knR * 10.f, 1, 0.35f + knR * 0.2f, c, 1.f, 1.f);
  text_c(dl, "purr~", 180.f, 272.f, R_FONT_14, 90.f, c, A(0.82f));
}

/* ---- rings (screen space, pip.js:253-282) --------------------------------- */
static void draw_rings(r_dl *dl, const pip_opts *o, float angle) {
  float batt = o->battery;
  float p[2 * 96];
  int n;
  if (batt < 0.f) batt = 0.f;
  if (batt > 100.f) batt = 100.f;

  fill_arc_premix(dl, 180.f, 180.f, 173.f, 4.f, 0.f, TAU_F, C_TRACK, A(0.14f));
  if (batt > 0.f) {
    r_rgb bc = batt <= 15.f ? C_BAT_LO : batt <= 30.f ? C_BAT_MD : C_BAT_HI;
    fill_arc_premix(dl, 180.f, 180.f, 173.f, 4.f, -0.5f * PI_F,
                    -0.5f * PI_F + TAU_F * batt / 100.f, bc, 255);
  }
  if (o->charging) {
    float a = -0.5f * PI_F + TAU_F * batt / 100.f;
    float bolt[12] = { 1.f, -7.f, -4.f, 1.f, 0.f, 1.f,
                       -1.f, 7.f, 4.f, -1.f, 0.f, -1.f };
    r_push(dl);
    r_translate(dl, 180.f + cosf(a) * 171.f, 180.f + sinf(a) * 171.f);
    r_rotate(dl, a + 0.5f * PI_F);
    fill_poly(dl, bolt, 6, C_BOLT, 255);
    r_pop(dl);
  }
  if (o->njob > 0) {
    int nj = o->njob > 6 ? 6 : o->njob;
    float per = (float)nj;
    for (int i = 0; i < nj; i++) {
      float wgt = o->job_weight[i] > 0.f ? o->job_weight[i] : 0.01f;
      float span = (TAU_F / per - 0.13f) * wgt * o->job_span;
      float ang = -0.5f * PI_F + ((float)i + 0.5f) * TAU_F / per + angle;
      int seg;
      if (span < 0.01f) span = 0.01f;
      seg = (int)ceilf(span / 0.12f);
      if (seg < 8) seg = 8;
      if (seg > 60) seg = 60;
      n = arc_stroke_pts(p, 96, 180.f, 180.f, 153.f, ang - 0.5f * span,
                         ang + 0.5f * span, seg);
      stroke_premix(dl, p, n, 7.f, o->job[i], A(0.9f), false);
    }
  }
}

/* ---- pose targets (pip.js:288-328) ---------------------------------------- */
static void target_pose(int st, float t, float phase, int variant, float stroke_x, float *q) {
  static const float rest[PIP_POSE_N] = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0 };
  memcpy(q, rest, sizeof(rest));
  switch (st) {
    case PIP_WORK: {
      /* 3.2 strokes/s, 16 cycles in 5 s; slow head bob closes the loop. */
      float u = modp(t, 5.f);
      q[P_TYPING] = 1.f; q[P_KEYBOARD] = 1.f; q[P_OPEN] = 0.76f;
      q[P_TILT] = sinf(u * TAU_F * 2.f / 5.f) * 0.023f;
      q[P_Y] = sinf(u * TAU_F * 3.f / 5.f) * 2.f;
      break;
    }
    case PIP_WORK_CRAZY: {
      /* 4.6 strokes/s, 23 cycles in 5 s; eyes dart and trade size. */
      float u = modp(t, 5.f);
      q[P_TYPING] = 1.f; q[P_KEYBOARD] = 1.f; q[P_OPEN] = 1.12f;
      q[P_ASYM] = 0.22f * sinf(u * TAU_F * 9.f / 5.f);
      q[P_GX] = 7.f * sinf(u * TAU_F * 10.f / 5.f);
      q[P_GY] = 3.f * cosf(u * TAU_F * 7.f / 5.f);
      q[P_TILT] = 0.055f * 1.15f * sinf(phase * 1.5f);
      q[P_Y] = 3.5f * 1.15f * sinf(phase * 1.5f);
      break;
    }
    case PIP_WORK_ANNOYED: {
      /* 3.6 strokes/s, 18 cycles in 5 s; heavy slams and a pout. */
      float u = modp(t, 5.f);
      q[P_TYPING] = 1.f; q[P_KEYBOARD] = 1.f; q[P_OPEN] = 0.76f;
      q[P_POUT] = 1.f;
      q[P_GY] = 4.f;
      q[P_GX] = 2.f * sinf(u * TAU_F * 3.f / 5.f);
      q[P_TILT] = 0.022f * 1.15f * sinf(u * TAU_F * 14.f / 5.f) +
                  0.03f * 1.15f * sinf(phase);
      q[P_Y] = 3.f * 1.15f * fabsf(sinf(phase));
      q[P_SQUASH] = 1.f - 0.04f * fabsf(sinf(phase));
      break;
    }
    case PIP_IDLE: {
      float leg = floorf(t / 1.65f), travel = modp(t / 1.65f, 1.f);
      float dir = (int)leg % 2 == 0 ? 1.f : -1.f;
      float move = 1.f - powf(1.f - travel, 3.f);
      float mx = 180.f + dir * (-57.f + 114.f * move);
      q[P_OPEN] = 0.9f;
      q[P_GX] = (mx - 180.f) * 0.16f;
      q[P_GY] = 11.f;
      q[P_TILT] = (mx - 180.f) * 0.0005f;
      break;
    }
    case PIP_CURIOUS: {
      float s2 = tanhf(sinf(t * 0.9f) * 3.f);
      q[P_ASYM] = 0.17f * s2;
      q[P_TILT] = 0.095f * s2;
      q[P_GX] = 6.f * s2;
      q[P_GY] = -5.f;
      q[P_OPEN] = 1.03f;
      break;
    }
    case PIP_THINKING:
      q[P_OPEN] = 0.8f;
      q[P_GX] = tanhf(sinf(t * 0.8f) * 4.f) * 9.f;
      q[P_GY] = -6.f; q[P_ASYM] = 0.07f * sinf(t); q[P_TILT] = 0.04f;
      break;
    case PIP_SEARCH: {
      static const float pos[4] = { -13.f, -3.f, 13.f, 4.f };
      float m = modp(t, 5.f);
      q[P_GX] = pos[((int)floorf(t / 0.85f)) % 4];
      q[P_OPEN] = (m > 2.f && m < 2.8f) ? 0.4f : 1.1f;
      q[P_GY] = -2.f;
      q[P_TILT] = q[P_GX] * 0.003f;
      break;
    }
    case PIP_READ: {
      static const float gx[3] = { -5.f, 0.f, 5.f };
      q[P_OPEN] = 0.72f;
      q[P_GX] = gx[((int)floorf(t * 2.7f)) % 3];
      q[P_GY] = 8.f; q[P_TILT] = -0.04f;
      break;
    }
    case PIP_WAIT:
      q[P_OPEN] = 0.4f; q[P_KEYBOARD] = 1.f; q[P_POUT] = 1.f;
      q[P_GX] = tanhf(sinf(t * 0.9f) * 4.f) * 11.f;
      q[P_TILT] = sinf(t) * 0.035f;
      break;
    case PIP_SLEEP:
      q[P_OPEN] = 0.03f; q[P_SLEEP] = 1.f; q[P_BRIGHT] = 0.58f;
      q[P_Y] = sinf(t * 0.95f) * 2.f; q[P_TILT] = -0.035f;
      break;
    case PIP_WAKE: {
      float rise = smf(t / 3.f);
      q[P_OPEN] = mixf(0.05f, 1.08f, rise);
      q[P_Y] = -4.f * sinf((t < 3.f ? t : 3.f) / 3.f * PI_F);
      q[P_O] = pulse(t, 1.5f, 0.8f);
      q[P_SLEEP] = 1.f - rise;
      break;
    }
    case PIP_APPROVAL:
      q[P_OPEN] = 1.13f;
      q[P_Y] = -fabsf(sinf(t * 2.8f)) * 4.f;
      q[P_O] = 0.55f;
      q[P_TILT] = 0.055f * sinf(t * 2.4f);
      break;
    case PIP_MCQ:
      q[P_OPEN] = 1.03f; q[P_ASYM] = 0.13f * sinf(t * 2.f);
      q[P_TILT] = sinf(t * 1.7f) * 0.06f; q[P_O] = 0.5f;
      break;
    case PIP_RETRY: {
      float p = modp(t, 5.f);
      q[P_OPEN] = 0.72f + 0.6f * pulse(p, 0.3f, 0.3f);
      q[P_O] = pulse(p, 0.3f, 0.4f);
      q[P_TILT] = -0.09f * pulse(p, 1.2f, 0.7f);
      break;
    }
    case PIP_DONE:
      q[P_HAPPY] = 1.f;
      q[P_Y] = -(sinf(t * 6.f) > 0.f ? sinf(t * 6.f) : 0.f) * 8.f *
               expf(-t * 0.3f);
      q[P_TILT] = sinf(t * 4.f) * 0.07f * expf(-t * 0.25f);
      break;
    case PIP_OFFLINE:
      q[P_OPEN] = 0.36f; q[P_BRIGHT] = 0.5f; q[P_POUT] = 1.f;
      break;
    case PIP_HUB:
      /* Keep the hub face still; the eyes are fixed lines, not animated pills. */
      q[P_O] = 0.55f;
      break;
    case PIP_DIZZY: {
      /* Spiral eyes, wobbling head and a short settle right after the shake. */
      float settle = t < 0.55f ? sinf(t * 55.f) * 0.12f * (1.f - t / 0.55f) : 0.f;
      q[P_OPEN] = 1.02f;
      q[P_GX] = sinf(t * 7.f) * 8.f;
      q[P_GY] = cosf(t * 6.f) * 5.f;
      q[P_TILT] = sinf(t * 5.2f) * 0.14f + settle;
      q[P_Y] = sinf(t * 6.5f) * 4.f;
      q[P_O] = 0.55f;
      q[P_SQUASH] = 1.f + sinf(t * 8.f) * 0.02f;
      break;
    }
    case PIP_TOOL_CALL: {
      int hammer = variant % 2 == 1;
      q[P_OPEN] = hammer ? 0.88f : 0.82f;
      q[P_GX] = hammer ? 4.f : sinf(t * 4.5f) * 4.f;
      q[P_GY] = 9.f;
      q[P_ASYM] = 0.1f * sinf(t * 3.2f);
      q[P_TILT] = hammer ? sinf(t * 2.4f * TAU_F) * 0.05f
                         : sinf(t * 2.5f) * 0.05f;
      q[P_Y] = hammer ? fmaxf(0.f, sinf(t * 2.4f * TAU_F)) * 3.f
                      : -fabsf(sinf(t * 3.2f)) * 2.f;
      break;
    }
    case PIP_RUN_CMD:
      q[P_OPEN] = 0.96f;
      q[P_GX] = sinf(t * 1.8f) * 2.f;
      q[P_TILT] = sinf(t * 2.1f) * 0.03f;
      q[P_Y] = sinf(t * 4.2f) * 1.5f;
      break;
    case PIP_STROKED:
      /* Blissful eyes, gaze toward the stroke, purr bounce and squash. */
      q[P_HAPPY] = 1.f;
      q[P_GX] = stroke_x * 10.f;
      q[P_GY] = -2.f;
      q[P_TILT] = stroke_x * 0.11f;
      q[P_Y] = -fabsf(sinf(t * 4.5f)) * 3.5f;
      q[P_SQUASH] = 1.f + sinf(t * 9.f) * 0.025f;
      break;
    default: break;
  }
}

/* ---- lifecycle ------------------------------------------------------------ */
r_rgb pip_state_color(int state) {
  if (state < 0 || state >= PIP_NSTATE) return PIP_COL[PIP_IDLE];
  return PIP_COL[state];
}

void pip_scene_init(pip_scene *s, uint32_t seed) {
  if (!s) return;
  memset(s, 0, sizeof(*s));
  s->seed = seed ? seed : 0xC0FFEEu;
  s->take_rng = s->seed * 2654435761u + 0x9E3779B9u;
  pip_scene_reset(s);
}

void pip_scene_reset(pip_scene *s) {
  if (!s) return;
  s->rng = s->seed;
  if (s->take_rng == 0) s->take_rng = 0x9E3779B9u;
  s->take = (xs32(&s->take_rng) >> 16) & 1u;   /* toolCall alternates wrench/hammer */
  s->phase = 0.f;
  s->next_key = 0.f;
  s->nkey = 0;
  s->pose_init = 0;
  s->ring_init = 0;
  s->job_ang = 0.f;
  s->job_span = 0.f;
  memset(s->pose, 0, sizeof(s->pose));
  memset(s->job_w, 0, sizeof(s->job_w));
}

void pip_opts_default(pip_opts *o) {
  static const r_rgb jobs[6] = {
    { 231, 177, 109 }, { 143, 205, 185 }, { 183, 155, 223 },
    { 223, 160, 176 }, { 140, 187, 220 }, { 197, 204, 137 }
  };
  if (!o) return;
  memset(o, 0, sizeof(*o));
  o->battery = 78.f;
  o->rings = true;
  o->effects = true;
  o->njob = 0;              /* refs show no arcs at rest; callers opt in */
  o->job_span = 1.f;
  o->job_spin = 0.f;
  for (int i = 0; i < 6; i++) {
    o->job[i] = jobs[i];
    o->job_weight[i] = 1.f;
  }
}

/* ---- frame ---------------------------------------------------------------- */
int pip_scene_frame(r_dl *dl, pip_scene *s, int state, float t, float dt,
                    const pip_opts *opt) {
  static const r_rgb C_ZC = { 144, 158, 220 };
  pip_opts def;
  float q[PIP_POSE_N];
  float k, blink, cyc, bph, left, right, impact, brightness, px, py, ptilt;
  r_rgb col;
  int variant;
  const float *pose;

  if (!dl || !s || state < 0 || state >= PIP_NSTATE) return R_ERR_PARAM;
  if (!(dt >= 0.f)) dt = 0.f;
  if (dt > 0.25f) dt = 0.25f;
  if (!opt) { pip_opts_default(&def); opt = &def; }
  variant = state == PIP_TOOL_CALL ? (int)s->take : opt->variant;

  if (is_typing_state(state))
    s->phase += dt * typing_rate(state) * TAU_F;
  target_pose(state, t, s->phase, variant, opt->stroke, q);
  k = 1.f - expf(-10.f * dt);
  for (int i = 0; i < PIP_POSE_N; i++)
    s->pose[i] = s->pose_init ? s->pose[i] + (q[i] - s->pose[i]) * k : q[i];
  s->pose_init = 1;
  pose = s->pose;

  {
    float expo = state == PIP_WORK_ANNOYED ? 0.35f : 0.62f;
    left = powf((1.f + sinf(s->phase)) * 0.5f, expo);
    right = powf((1.f - sinf(s->phase)) * 0.5f, expo);
  }
  impact = fmaxf(powf(1.f - left, 7.f), powf(1.f - right, 7.f));

  if (is_typing_state(state)) {
    blink = work_blink(modp(t, 5.f));
  } else {
    /* Restored to the 3.3 s cadence used by the demo. */
    cyc = 3.3f + 0.55f * sinf(t * 0.53f);
    bph = modp(t + 1.05f, cyc) / 0.22f;
    blink = bph < 1.f ? sinf(bph * PI_F) : 0.f;
  }

  {
    r_rgb target = opt->has_color ? opt->color : pip_state_color(state);
    float kc = 1.f - expf(-6.f * dt);
    if (!s->ink_init) {
      s->ink = target;
      s->ink_init = 1;
    } else {
      s->ink.r = mixf(s->ink.r, target.r, kc);
      s->ink.g = mixf(s->ink.g, target.g, kc);
      s->ink.b = mixf(s->ink.b, target.b, kc);
    }
    col = s->ink;
  }
  {
    r_pal pal = dl->pal;
    pal.bg = opt->has_bg ? opt->bg : C_BG;
    pal.ink = col;
    r_set_palette(dl, &pal);
  }

  /* 1. rings, screen space; job weights/span/angle ease in the scene */
  {
    pip_opts ro = *opt;
    float kr = 1.f - expf(-8.f * dt);
    if (!s->ring_init) {
      for (int i = 0; i < 6; i++) s->job_w[i] = ro.job_weight[i];
      s->job_span = ro.job_span;
      s->ring_init = 1;
    } else {
      for (int i = 0; i < 6; i++)
        s->job_w[i] += (ro.job_weight[i] - s->job_w[i]) * kr;
      s->job_span += (ro.job_span - s->job_span) * kr;
    }
    s->job_ang += ro.job_spin * dt;
    for (int i = 0; i < 6; i++) ro.job_weight[i] = s->job_w[i];
    ro.job_span = s->job_span;
    ro.job_spin = 0.f;
    if (ro.rings) draw_rings(dl, &ro, s->job_ang);
  }

  /* 2. scene group */
  r_push(dl);
  r_translate(dl, 180.f, 180.f);
  r_scale(dl, S, S);
  r_translate(dl, -180.f, -180.f);

  /* 3. keyboard (under face), pushed down by impact */
  {
    float ky = 278.f + impact * 3.f * pose[P_TYPING];
    if (pose[P_KEYBOARD] > 0.01f) {
      bool press[3][11];
      memset(press, 0, sizeof(press));
      if (is_typing_state(state)) {
        for (int r = 0; r < 3; r++)
          for (int j = 0; j < 11; j++)
            if ((j < 5 ? left : right) < 0.15f && j % 3 == r % 3)
              press[r][j] = true;
      }
      if (state == PIP_WAIT) {
        float tp = modp(t, 3.4f);
        float tap = tp < 1.65f ? fmaxf(0.f, sinf(tp * 11.5f)) : 0.f;
        if (tap < 0.12f) press[0][8] = true;
      }
      keyboard(dl, ky, col, pose[P_KEYBOARD], press,
               sinf(s->phase) * 0.013f * pose[P_TYPING], opt->agents, opt->job);
    }
  }

  /* 4. typing paws, under the face */
  if (pose[P_TYPING] > 0.01f) {
    for (int side = -1; side <= 1; side += 2) {
      float lift = side < 0 ? left : right;
      /* Keep the new eyes readable: the full shipped lift covers the crazy
         eye and the annoyed half-lid. Frantic keeps the shipped path. */
      float pawLift = lift;
      if (state == PIP_WORK_CRAZY) pawLift *= 0.62f;
      else if (state == PIP_WORK_ANNOYED) pawLift *= 0.78f;
      paw(dl, 180.f + (float)side * (56.f + pawLift * 8.f),
          276.f - pawLift * 97.f, side, pawLift, col, pose[P_TYPING], 1.f);
    }
  }

  /* 5. face */
  brightness = pose[P_BRIGHT];
  px = pose[P_GX]; py = pose[P_GY]; ptilt = pose[P_TILT];
  r_push(dl);
  r_set_alpha(dl, A(brightness));
  r_translate(dl, 180.f, 132.f + pose[P_Y]);
  r_rotate(dl, ptilt);
  r_scale(dl, pose[P_SQUASH], 1.f / pose[P_SQUASH]);
  r_translate(dl, -180.f, -132.f);

  for (int side = -1; side <= 1; side += 2) {
    float ex = 180.f + (float)side * 62.f + px;
    float ey = 126.f + py;
    uint8_t ea = A(brightness);
    if (state == PIP_HUB) {
      /* Literal line eyes: fixed width, no blink, no glow. */
      fill_rrect(dl, ex - 22.f, ey - 2.f, 44.f, 4.f, 2.f, col, ea);
      continue;
    }
    float opening = fmaxf(0.025f, pose[P_OPEN] + (float)side * pose[P_ASYM]);
    float eh = fminf(116.f, fmaxf(3.f, 78.f * opening * (1.f - blink)));
    int happy = pose[P_HAPPY] > 0.65f && state != PIP_HUB;
    int closed = pose[P_SLEEP] > 0.7f;
    if (state == PIP_RUN_CMD && eh > 5.f) {
      cmd_eye(dl, ex, ey, 42.f, eh, (int)side, t, col, ea);
    } else if (state == PIP_DIZZY && eh > 5.f) {
      spiral_eye(dl, ex, ey, 42.f, eh, t, col, ea);
    } else if (happy) {
      arch_eye(dl, ex, ey, 49.f, col, 10.5f, 9.f, ea);
    } else if (closed) {
      arch_eye(dl, ex, ey, 42.f, col, 5.f, 5.f, ea);
    } else if (state == PIP_WORK_ANNOYED && eh > 10.f) {
      /* Flat top lid: the lower half of the pill remains. */
      r_set_glow(dl, 2.5f * (1.f - blink));
      half_lid(dl, ex, ey, eh, col, ea);
      r_set_glow(dl, 0.f);
    } else {
      /* Shrink the eye pill to a line. The old arch+glow blink read as a cyan
       * capsule with a white bar across the eye on the panel. */
      r_set_glow(dl, 2.5f * (1.f - blink));
      fill_rrect(dl, ex - 21.f, ey - eh * 0.5f, 42.f, eh, 20.f, col, ea);
      r_set_glow(dl, 0.f);
    }
  }

  mouth(dl, 180.f, 190.f, col, pose[P_POUT], pose[P_O], state == PIP_HUB,
        is_typing_state(state) && state != PIP_WORK_ANNOYED &&
            pose[P_TYPING] > 0.3f,
        variant == 1 ? -1 : 1, state == PIP_WORK_CRAZY, A(brightness));
  if (state == PIP_OFFLINE)
    wifi(dl, 180.f, 82.f, t, col, 2.8f, 1.75f, A(brightness));
  if (state == PIP_SLEEP) drool(dl, 167.f, 191.f, t, col, A(brightness));
  r_pop(dl);

  /* 6. per-state props (pip.js:413-519), painted after the face */
  if (state == PIP_IDLE) {
    float leg = floorf(t / 1.65f), travel = modp(t / 1.65f, 1.f);
    float dir = (int)leg % 2 == 0 ? 1.f : -1.f;
    float move = 1.f - powf(1.f - travel, 3.f);
    float mx = 180.f + dir * (-57.f + 114.f * move);
    /* ease the batting paw in and out: expf(-14t) jumped the other paw by
     * 28 px at the 1.65 s leg flip. */
    float contact = smf(travel / 0.12f) * (1.f - smf((travel - 0.12f) / 0.30f));
    toy_mouse(dl, mx, 275.f, (int)dir, col, sinf(t * 9.f));
    paw(dl, 112.f + (dir > 0.f ? contact : 0.f) * 28.f,
        255.f + (dir > 0.f ? contact : 0.f) * 10.f, -1, 0.45f, col, 1.f, 1.f);
    paw(dl, 248.f - (dir < 0.f ? contact : 0.f) * 28.f,
        255.f + (dir < 0.f ? contact : 0.f) * 10.f, 1, 0.45f, col, 1.f, 1.f);
  }
  if (state == PIP_WAIT) {
    float tp = modp(t, 3.4f);
    float tap = tp < 1.65f ? fmaxf(0.f, sinf(tp * 11.5f)) : 0.f;
    paw(dl, 130.f, 268.f, -1, 0.18f, col, 1.f, 1.f);
    paw(dl, 230.f, 268.f - tap * 9.f, 1, 0.18f, col, 1.f, 1.f);
  }
  if (state == PIP_WAKE) {
    float stretch = sinf((t < 3.f ? t : 3.f) / 3.f * PI_F);
    paw(dl, 111.f, 247.f - stretch * 31.f, -1, 0.8f, col, 1.f, 1.f);
    paw(dl, 249.f, 247.f - stretch * 31.f, 1, 0.8f, col, 1.f, 1.f);
  }
  if (state == PIP_READ) {
    note(dl, 180.f, 244.f, sinf(t) * 0.035f, col, 255);
    paw(dl, 146.f, 260.f, -1, 0.5f, col, 1.f, 1.f);
    paw(dl, 214.f, 260.f, 1, 0.5f, col, 1.f, 1.f);
  }
  if (state == PIP_APPROVAL) {
    float wob = sinf(t * 2.f) * 2.f;
    float q[2 * 40];
    int n;
    r_push(dl);
    r_translate(dl, 180.f, 248.f + wob);
    r_rotate(dl, sinf(t * 2.f) * 0.035f);
    fill_rrect(dl, -50.f, -25.f, 100.f, 51.f, 11.f, col, A(0.09f));
    n = rrect_path(q, 40, -50.f, -25.f, 100.f, 51.f, 11.f);
    stroke_path(dl, q, n, 1.f * S, col, 255, true);
    text_c(dl, "APPROVE?", 0.f, 2.f, R_FONT_14, 84.f, col, 255);
    r_pop(dl);
    paw(dl, 115.f, 253.f + wob, -1, 0.5f, col, 1.f, 1.f);
    paw(dl, 245.f, 253.f + wob, 1, 0.5f, col, 1.f, 1.f);
  }
  if (state == PIP_MCQ) {
    static const char *const abc[3] = { "A", "B", "C" };
    for (int i = -1; i <= 1; i++) {
      float q[2 * 40];
      int n;
      r_push(dl);
      r_translate(dl, 180.f + (float)i * 33.f, 228.f);
      r_rotate(dl, (float)i * 0.16f);
      fill_rrect(dl, -26.f, -22.f, 52.f, 44.f, 7.f, C_NOTE, 255);
      n = rrect_path(q, 40, -26.f, -22.f, 52.f, 44.f, 7.f);
      stroke_path(dl, q, n, 1.f * S, col, 255, true);
      text_c(dl, abc[i + 1], 0.f, 1.f, R_FONT_18, 30.f, col, 255);
      r_pop(dl);
    }
    paw(dl, 115.f, 253.f, -1, 0.5f, col, 1.f, 1.f);
    paw(dl, 245.f, 253.f, 1, 0.5f, col, 1.f, 1.f);
  }
  if (state == PIP_DONE) {
    float hop = fabsf(sinf(t * 3.4f)) * 11.f;
    float used = text_c(dl, "DONE", 180.f, 248.f, R_FONT_22, 142.f, col, 255);
    paw(dl, 112.f, 235.f - hop, -1, 0.8f, col, 1.f, 1.f);
    paw(dl, 248.f, 235.f - hop, 1, 0.8f, col, 1.f, 1.f);
    if (opt->effects) {
      float bw = used / S;
      float rx = fmaxf(65.f, fminf(88.f, bw * 0.5f + 30.f));
      float ry = fmaxf(29.f, 25.f * 0.5f + 22.f);
      for (int i = 0; i < 6; i++) {
        float a = (float)i * TAU_F / 6.f + t * 0.65f;
        fill_ell(dl, 180.f + cosf(a) * rx, 248.f + sinf(a) * ry, 2.7f, 2.7f,
                 col, A(0.65f));
      }
    }
  }
  if (state == PIP_HUB) {
    hub_glyph(dl, t, col);
    paw(dl, 148.f, 284.f, -1, 0.25f, col, 1.f, 0.72f);
    paw(dl, 212.f, 284.f, 1, 0.25f, col, 1.f, 0.72f);
  }
  if (state == PIP_THINKING) {
    float p[6];
    p[0] = 158.f; p[1] = 240.f;
    p[2] = 171.f; p[3] = 250.f;
    p[4] = 158.f; p[5] = 260.f;
    stroke_path(dl, p, 3, 5.f * S, col, 255, false);
    fill_rrect(dl, 179.f, 256.5f, 17.f, 6.f, 0.f, col,
               A(0.55f + 0.45f * fabsf(sinf(t * 2.6f))));
  }
  if (state == PIP_CURIOUS)
    text_c(dl, "?", 180.f, 74.f, R_FONT_18, 40.f, col, 255);
  if (state == PIP_SEARCH) {
    float kk = 1.f + 0.18f * sinf(t * 2.1f);
    float p[4];
    r_push(dl);
    r_translate(dl, 256.f, 224.f);
    r_scale(dl, kk, kk);
    r_translate(dl, -256.f, -224.f);
    r_set_color(dl, col);
    r_set_alpha(dl, 255);
    r_set_premix(dl, false);
    r_fill_arc(dl, 250.f, 216.f, 16.5f, 3.f, 0.f, TAU_F);
    p[0] = 261.f; p[1] = 228.f; p[2] = 273.f; p[3] = 242.f;
    stroke_path(dl, p, 2, 5.f * S, col, 255, false);
    r_pop(dl);
  }
  if (state == PIP_RETRY) {
    float p = 0.55f + 0.45f * fabsf(sinf(t * 3.f));
    mark_refresh(dl, 272.f, 248.f, col, 255);
    text_c(dl, "!", 274.f, 108.f, R_FONT_22, 30.f, col, A(p));
  }
  if (state == PIP_SLEEP) {
    for (int i = 0; i < 3; i++) {
      float z = modp(t * 0.23f + (float)i * 0.33f, 1.f);
      z_mark(dl, 238.f + z * 30.f, 86.f - z * 52.f, 18.f + z * 16.f, C_ZC,
             A((1.f - z) * 0.65f));
    }
  }
  if (state == PIP_OFFLINE)
    text_c(dl, "OFFLINE", 180.f, 262.f, R_FONT_18, 160.f, col, A(0.85f));
  if (state == PIP_DIZZY) dizzy_props(dl, t, col);
  if (state == PIP_TOOL_CALL) tool_props(dl, t, col, variant);
  if (state == PIP_RUN_CMD) run_cmd_props(dl, t, col);
  if (state == PIP_STROKED) stroked_props(dl, t, col, opt->effects);

  /* 7. flying-key particles, last inside the scene (pip.js:521-539) */
  if (is_typing_state(state) && t >= s->next_key) {
    if (s->nkey < PIP_MAX_KEYS) {
      int side = left < right ? -1 : 1;
      pip_part *v = &s->key[s->nkey++];
      v->x = 180.f + (float)side * 52.f;
      v->y = 269.f;
      v->vx = (float)side * (50.f + rnd01(&s->rng) * 45.f);
      v->vy = -100.f - rnd01(&s->rng) * 80.f;
      v->a = 0.f;
      v->va = (rnd01(&s->rng) - 0.5f) * 6.f;
      v->age = 0.f;
    }
    s->next_key = t + 0.18f;
  }
  for (int i = s->nkey - 1; i >= 0; i--)
    if (s->key[i].age >= 0.8f) s->key[i] = s->key[--s->nkey];
  for (int i = 0; i < s->nkey; i++) {
    pip_part *v = &s->key[i];
    float p[4], a;
    v->age += dt;
    v->x += v->vx * dt;
    v->y += v->vy * dt;
    v->vy += 235.f * dt;
    v->a += v->va * dt;
    a = 1.f - v->age / 0.8f;
    if (a <= 0.f) continue;
    r_push(dl);
    r_translate(dl, v->x, v->y);
    r_rotate(dl, v->a);
    fill_rrect(dl, -8.f, -7.f, 16.f, 14.f, 3.f, C_KEY, A(a));
    {
      float q[2 * 40];
      int n = rrect_path(q, 40, -8.f, -7.f, 16.f, 14.f, 3.f);
      stroke_path(dl, q, n, 1.f * S, col, A(0.8f * a), true);
    }
    p[0] = -3.f; p[1] = -2.f; p[2] = 3.f; p[3] = -2.f;
    stroke_path(dl, p, 2, 1.2f * S, col, A(0.7f * a), false);
    p[0] = -3.f; p[1] = 2.f; p[2] = 1.f; p[3] = 2.f;
    stroke_path(dl, p, 2, 1.2f * S, col, A(0.7f * a), false);
    r_pop(dl);
  }

  r_pop(dl);   /* scene */

  /* 8. params.text: screen space, last, over the job ring (design §6). */
  if (opt->text && *opt->text) caption(dl, opt->text, col, A(0.85f));
  return dl->err ? dl->err : R_OK;
}
