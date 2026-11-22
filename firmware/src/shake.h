#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Time-based shake counter.
 *
 * The accelerometer reports gravity plus motion. A slow per-axis low-pass
 * removes gravity, leaving the dynamic vector. A deliberate shake makes the
 * vector swing one way, then the other. A swing only counts when it stays
 * above a low gate for at least 120 ms, so a bump or a stroke cannot produce
 * the six alternating swings that trigger. Six swings (left, right, left,
 * right, left, right) must land within 3 s, no more than 0.8 s apart.
 */
typedef struct {
    float gx, gy, gz;       /* gravity estimate, raw counts */
    float thr2;             /* squared gate threshold, raw counts^2 */
    float ldx, ldy, ldz;    /* direction of the last counted swing */
    int64_t swing_start_us;
    int64_t first_swing_us;
    int64_t last_swing_us;
    int64_t last_active_us;
    int64_t cooldown_until_us;
    int swing_count;
    uint32_t swing_total;
    bool have_dir;
    bool in_swing;
    bool seeded;
} shake_detector;

void shake_init(shake_detector *s, int sensitivity);
void shake_set_sensitivity(shake_detector *s, int level);
bool shake_feed(shake_detector *s, int x, int y, int z, int64_t now_us);
