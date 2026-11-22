#include "stroke.h"

#include <math.h>

#define STROKE_MIN_LEG 70.f             /* px net travel per one-way pass */
#define STROKE_MAX_GAP_US 300000LL      /* a longer pause starts over */
#define STROKE_SEQUENCE_US 6000000LL    /* six passes must land this fast */
#define STROKE_REVERSE_DOT (-0.5f)      /* >= ~120 degrees from the last pass */
#define STROKE_DEADBAND 1.5f            /* ignore stationary jitter */
#define STROKE_RECENT_US 400000LL
#define STROKE_MIN_RECENT_PATH 60.f     /* >= ~150 px/s across that window */
#define STROKE_PASSES 6
#define STROKE_RECENT_MAX 16

static void clear_recent(stroke_detector *s)
{
    s->recent_count = 0;
    s->recent_head = 0;
}

static void start_run(stroke_detector *s, int x, int y, int64_t now_us)
{
    s->last_move_us = now_us;
    s->last_x = (int16_t)x;
    s->last_y = (int16_t)y;
    s->anchor_x = (float)x;
    s->anchor_y = (float)y;
    s->prev_dx = 0.f;
    s->prev_dy = 0.f;
    s->have_prev = false;
    s->legs = 0;
    s->first_leg_us = 0;
    s->triggered = false;
    clear_recent(s);
}

static void push_recent(stroke_detector *s, float dist, int64_t now_us)
{
    s->recent[s->recent_head].dist = dist;
    s->recent[s->recent_head].us = now_us;
    s->recent_head = (s->recent_head + 1) % STROKE_RECENT_MAX;
    if (s->recent_count < STROKE_RECENT_MAX) s->recent_count++;
}

static float recent_path(const stroke_detector *s, int64_t now_us)
{
    float total = 0.f;
    for (int i = 0; i < s->recent_count; i++) {
        int idx = (s->recent_head - 1 - i + STROKE_RECENT_MAX) %
                  STROKE_RECENT_MAX;
        if (now_us - s->recent[idx].us <= STROKE_RECENT_US) {
            total += s->recent[idx].dist;
        }
    }
    return total;
}

void stroke_init(stroke_detector *s)
{
    *s = (stroke_detector){ 0 };
}

void stroke_down(stroke_detector *s, int x, int y, int64_t now_us)
{
    s->down = true;
    start_run(s, x, y, now_us);
}

void stroke_up(stroke_detector *s)
{
    s->down = false;
    s->triggered = false;
}

bool stroke_feed(stroke_detector *s, int x, int y, int64_t now_us)
{
    if (!s->down) return false;

    float dx = (float)(x - s->last_x);
    float dy = (float)(y - s->last_y);
    float dist = sqrtf(dx * dx + dy * dy);

    if (dist < STROKE_DEADBAND) return false;

    if (now_us - s->last_move_us > STROKE_MAX_GAP_US) {
        /* The finger paused (or the bus did). Forget the passes so far. */
        start_run(s, x, y, now_us);
        return false;
    }

    s->last_x = (int16_t)x;
    s->last_y = (int16_t)y;
    s->last_move_us = now_us;
    push_recent(s, dist, now_us);

    /* Already three passes in: any continued movement keeps the rub alive. */
    if (s->triggered) return true;

    if (s->legs > 0 && now_us - s->first_leg_us > STROKE_SEQUENCE_US) {
        start_run(s, x, y, now_us);
        return false;
    }

    /* Three passes are counted but the finger is still too slow: hold the
     * count and trigger as soon as it speeds up. */
    if (s->legs >= STROKE_PASSES &&
        recent_path(s, now_us) >= STROKE_MIN_RECENT_PATH) {
        s->triggered = true;
        return true;
    }

    float ax = (float)x - s->anchor_x;
    float ay = (float)y - s->anchor_y;
    float mag = sqrtf(ax * ax + ay * ay);
    if (mag < STROKE_MIN_LEG) return false;

    float ux = ax / mag;
    float uy = ay / mag;
    if (s->have_prev &&
        ux * s->prev_dx + uy * s->prev_dy > STROKE_REVERSE_DOT) {
        /* Same or sideways direction: this is not the return pass. */
        return false;
    }

    s->legs++;
    if (s->legs == 1) s->first_leg_us = now_us;
    s->prev_dx = ux;
    s->prev_dy = uy;
    s->have_prev = true;
    s->anchor_x = (float)x;
    s->anchor_y = (float)y;

    if (s->legs >= STROKE_PASSES &&
        recent_path(s, now_us) >= STROKE_MIN_RECENT_PATH) {
        s->triggered = true;
        return true;
    }
    return false;
}
