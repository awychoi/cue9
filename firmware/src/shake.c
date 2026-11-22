#include "shake.h"

#include <math.h>

#define RAW_PER_G 8192.0f
#define GRAVITY_ALPHA 0.02f     /* ~0.5 s at the 100 Hz sample rate */
#define SHAKE_SWINGS 6
#define SHAKE_WINDOW_US 3000000LL
#define SHAKE_MAX_GAP_US 800000LL
#define SHAKE_IDLE_RESET_US 1000000LL
#define SHAKE_MIN_SWING_US 120000LL
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

/* Count one established swing. Six swings inside the window, with no gap
 * longer than 0.8 s, trigger dizzy. */
static bool count_swing(shake_detector *s, int64_t now_us)
{
    if (s->swing_count > 0 &&
        (now_us - s->last_swing_us > SHAKE_MAX_GAP_US ||
         now_us - s->first_swing_us > SHAKE_WINDOW_US)) {
        s->swing_count = 0;
    }
    if (s->swing_count == 0) s->first_swing_us = now_us;
    s->last_swing_us = now_us;
    s->swing_count++;
    s->swing_total++;

    if (s->swing_count >= SHAKE_SWINGS) {
        s->swing_count = 0;
        s->cooldown_until_us = now_us + SHAKE_COOLDOWN_US;
        return true;
    }
    return false;
}

bool shake_feed(shake_detector *s, int x, int y, int z, int64_t now_us)
{
    float ax = (float)x, ay = (float)y, az = (float)z;
    if (!s->seeded) {
        s->gx = ax;
        s->gy = ay;
        s->gz = az;
        s->last_active_us = now_us;
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
        /* A pause means the next movement is the start of a new shake. */
        if (s->have_dir &&
            now_us - s->last_active_us > SHAKE_IDLE_RESET_US) {
            s->have_dir = false;
            s->swing_count = 0;
        }
        return false;
    }
    s->last_active_us = now_us;

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
        if (now_us < s->cooldown_until_us) return false;
        return count_swing(s, now_us);
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
    return count_swing(s, now_us);
}
