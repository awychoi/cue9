#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Back-and-forth gate for a deliberate screen stroke ("petting").
 *
 * Thresholds and timings live in stroke.c. A page swipe is one directional
 * pass; petting is several alternating passes, each long enough and fast
 * enough to rule out a drag. Once triggered, continued movement keeps
 * returning true so the caller can extend the reaction; a pause lets it fade.
 */
typedef struct {
    bool down;
    bool triggered;         /* a run has been recognized */
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

/* Feed a sample while the finger is down. True once the rub is recognized,
 * and on later movement while it continues. Callers should throttle
 * re-arming; this can be true on every 30 ms poll. */
bool stroke_feed(stroke_detector *s, int x, int y, int64_t now_us);

/* End the run on touch-up. */
void stroke_up(stroke_detector *s);
