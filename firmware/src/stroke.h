#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Back-and-forth gate for a deliberate screen stroke ("petting").
 *
 * A page swipe is one directional pass. Petting is six passes,
 * each covering 70 px, alternating direction: each pass must point at least
 * ~120 degrees away from the previous one. The passes must land within 6 s
 * with no pause over 300 ms, and the last 400 ms must contain 60 px of
 * movement (about 150 px/s) so a slow drag does not count. Any start point
 * and any stroke direction qualify. Once the sixth pass lands, continued
 * movement keeps returning true so the caller can extend the reaction; a
 * pause lets it fade.
 */
typedef struct {
    bool down;
    bool triggered;         /* six alternating passes counted */
    int64_t last_move_us;
    int16_t last_x, last_y;
    float anchor_x, anchor_y;   /* start of the pass being measured */
    float prev_dx, prev_dy;     /* direction of the last counted pass */
    bool have_prev;
    int legs;
    int64_t first_leg_us;
    struct {
        float dist;
        int64_t us;
    } recent[16];           /* last ~480 ms at the 30 ms poll rate */
    int recent_count;
    int recent_head;
} stroke_detector;

void stroke_init(stroke_detector *s);

/* Start a run on touch-down. */
void stroke_down(stroke_detector *s, int x, int y, int64_t now_us);

/* Feed a sample while the finger is down. True once six alternating passes
 * have landed while moving at speed, and on later movement while the rub
 * continues. Callers should throttle re-arming; this can be true on every
 * 30 ms poll. */
bool stroke_feed(stroke_detector *s, int x, int y, int64_t now_us);

/* End the run on touch-up. */
void stroke_up(stroke_detector *s);
