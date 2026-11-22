#include "shake.h"

#include <math.h>

#define RAW_PER_G 8192.0f
#define GRAVITY_ALPHA 0.02f     /* ~0.5 s at the 100 Hz sample rate */
#define SHAKE_REVS 3
#define SHAKE_WINDOW_US 1500000LL
#define SHAKE_MIN_SWING_US 80000LL
#define SHAKE_COOLDOWN_US 2000000LL
#define REVERSAL_DOT -0.35f     /* about 110 degrees from the last swing */

/* Dynamic gate in hundredths of a g, hard to easy. The gate only decides
 * whether a swing is real motion; the count is time based. */
static const int s_gate_cg[5] = { 20, 15, 10, 8, 5 };

static float threshold_sq(int cg)
{
    float counts = (float)cg / 100.0f * RAW_PER_G;
    return counts * counts;
}

void shake_set_sensitivity(shake_detector *s, int level)
{
    if (level < 1) level = 1;
    if (level > 5) level = 5;
    s->thr2 = threshold_sq(s_gate_cg[level - 1]);
}

void shake_init(shake_detector *s, int sensitivity)
{
    *s = (shake_detector){ 0 };
    shake_set_sensitivity(s, sensitivity);
}

bool shake_feed(shake_detector *s, int x, int y, int z, int64_t now_us)
{
    float ax = (float)x, ay = (float)y, az = (float)z;
    if (!s->seeded) {
        s->gx = ax;
        s->gy = ay;
        s->gz = az;
        s->seeded = true;
        return false;
    }

    s->gx += GRAVITY_ALPHA * (ax - s->gx);
    s->gy += GRAVITY_ALPHA * (ay - s->gy);
    s->gz += GRAVITY_ALPHA * (az - s->gz);

    float dx = ax - s->gx;
    float dy = ay - s->gy;
    float dz = az - s->gz;
    float dyn2 = dx * dx + dy * dy + dz * dz;

    if (dyn2 < s->thr2) {
        s->in_swing = false;
        return false;
    }
    if (!s->in_swing) {
        s->in_swing = true;
        s->swing_start_us = now_us;
        return false;
    }
    /* A bump or impact ring is over before this; only a real swing counts. */
    if (now_us - s->swing_start_us < SHAKE_MIN_SWING_US) return false;

    float mag = sqrtf(dyn2);
    if (!s->have_dir) {
        s->ldx = dx;
        s->ldy = dy;
        s->ldz = dz;
        s->have_dir = true;
        return false;
    }

    float lmag = sqrtf(s->ldx * s->ldx + s->ldy * s->ldy + s->ldz * s->ldz);
    float dot = dx * s->ldx + dy * s->ldy + dz * s->ldz;
    if (dot > 0.0f) {
        /* Still the same swing; follow it through a curve. */
        s->ldx = dx;
        s->ldy = dy;
        s->ldz = dz;
        return false;
    }
    if (dot > REVERSAL_DOT * mag * lmag) return false;

    s->ldx = dx;
    s->ldy = dy;
    s->ldz = dz;

    if (now_us < s->cooldown_until_us) return false;
    if (s->rev_count > 0 && now_us - s->rev_us[s->rev_count - 1] > SHAKE_WINDOW_US) {
        s->rev_count = 0;
    }

    s->rev_total++;
    if (s->rev_count < SHAKE_REVS) {
        s->rev_us[s->rev_count++] = now_us;
    } else {
        s->rev_us[0] = s->rev_us[1];
        s->rev_us[1] = s->rev_us[2];
        s->rev_us[2] = now_us;
    }

    if (s->rev_count >= SHAKE_REVS &&
        now_us - s->rev_us[0] <= SHAKE_WINDOW_US) {
        s->rev_count = 0;
        s->cooldown_until_us = now_us + SHAKE_COOLDOWN_US;
        return true;
    }
    return false;
}
