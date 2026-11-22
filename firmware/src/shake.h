#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Time-based shake counter.
 *
 * The accelerometer reports gravity plus motion. A slow per-axis low-pass
 * removes gravity, leaving the dynamic vector. A deliberate shake makes the
 * vector swing one way, then the other. A swing only counts when it stays
 * above a low gate for at least 80 ms, so a bump or a stroke cannot produce
 * the three opposing swings that trigger. Three swings inside 1.5 s trigger.
 */
typedef struct {
    float gx, gy, gz;       /* gravity estimate, raw counts */
    float thr2;             /* squared gate threshold, raw counts^2 */
    float ldx, ldy, ldz;    /* direction of the last qualified swing */
    int64_t swing_start_us;
    int64_t rev_us[3];      /* timestamps of the latest three reversals */
    int64_t cooldown_until_us;
    int rev_count;
    uint32_t rev_total;
    bool have_dir;
    bool in_swing;
    bool seeded;
} shake_detector;

void shake_init(shake_detector *s, int sensitivity);
void shake_set_sensitivity(shake_detector *s, int level);
bool shake_feed(shake_detector *s, int x, int y, int z, int64_t now_us);
