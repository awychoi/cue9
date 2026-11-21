/* font.c — thin reader for the baked Inter Bold face (font_baked.c).
 *
 * The 96 glyphs x 4 sizes live as 4-bpp masks in .rodata, so a device link
 * keeps them in flash (20,064 B), not .bss.  The baker is
 * renderer/tools/bake_font.py; source face is the OFL Inter variable font at
 * brand/decided/app/fonts/InterVariable.woff2, weight Bold.
 *
 * Glyph ids: printable ASCII codepoint, or 0x2026.  Unknown -> '?'.  Lowercase
 * is preserved (params.text needs it); labels pass uppercase themselves.
 * Masks are unpacked into one small static A8 scratch per r_render call; the
 * render path stays single-threaded.
 */
#include "raster.h"
#include "font_baked.h"

#define F_MAX_W 80
#define F_MAX_H 80

static uint8_t g_a8[F_MAX_W * F_MAX_H];

static const r_font_glyph_meta *meta_for(int font, uint16_t cp) {
  const r_font_face *f;
  int gid;
  if (font < 0) font = 0;
  if (font >= R_FONT_NFACE) font = R_FONT_NFACE - 1;
  f = &r_font_faces[font];
  if (cp == 0x2026u) gid = 95;
  else if (cp == 0x00B0u) gid = 96;
  else if (cp == 0x00B7u) gid = 97;
  else {
    if (cp < 32u || cp > 126u) cp = (uint16_t)'?';
    gid = (int)cp - 32;
  }
  if (gid < 0 || gid >= f->nglyph) gid = (int)'?' - 32;
  return &f->meta[gid];
}

void r_font_init(void) { /* masks are const; nothing to build */ }

void r_font_metrics(int font, int *w, int *h, int *adv, int *cap, int *gap) {
  const r_font_face *f;
  if (font < 0) font = 0;
  if (font >= R_FONT_NFACE) font = R_FONT_NFACE - 1;
  f = &r_font_faces[font];
  if (w) *w = f->size;            /* nominal em width */
  if (h) *h = f->ascent;          /* baseline -> top */
  if (adv) *adv = f->size;        /* nominal advance, not a layout value */
  if (cap) *cap = f->cap;
  if (gap) *gap = f->descent;     /* baseline -> bottom */
}

int r_font_glyph(int font, uint16_t cp, int *w, int *h, int *adv, int *bx,
                 int *by) {
  const r_font_glyph_meta *m = meta_for(font, cp);
  if (w) *w = m->w;
  if (h) *h = m->h;
  if (adv) *adv = m->adv;
  if (bx) *bx = m->bx;
  if (by) *by = m->by;
  return m->w > 0 ? m->h : 0;
}

const uint8_t *r_font_mask(int font, uint16_t cp, int *w, int *h) {
  const r_font_face *f;
  const r_font_glyph_meta *m = meta_for(font, cp);
  int gw = m->w, gh = m->h, stride = (gw + 1) / 2;
  if (font < 0) font = 0;
  if (font >= R_FONT_NFACE) font = R_FONT_NFACE - 1;
  f = &r_font_faces[font];
  if (w) *w = gw;
  if (h) *h = gh;
  if (gw <= 0 || gh <= 0) return g_a8;
  if (gw > F_MAX_W || gh > F_MAX_H) return g_a8;
  for (int y = 0; y < gh; y++) {
    for (int x = 0; x < gw; x++) {
      uint8_t b = f->mask[m->off + y * stride + x / 2];
      uint8_t q = (x & 1) ? (uint8_t)(b & 15u) : (uint8_t)(b >> 4);
      g_a8[y * gw + x] = (uint8_t)(q * 17u);
    }
  }
  return g_a8;
}
