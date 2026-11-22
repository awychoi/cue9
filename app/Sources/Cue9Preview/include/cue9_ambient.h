#ifndef CUE9_AMBIENT_H
#define CUE9_AMBIENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cue9_ambient cue9_ambient;

/* page: 1 = clock, 2 = weather. */
cue9_ambient *cue9_ambient_create(void);
void cue9_ambient_destroy(cue9_ambient *ambient);

int cue9_ambient_render(cue9_ambient *ambient, int page,
                        int64_t local_epoch, int fmt24, int have_time,
                        const char *status,
                        uint8_t status_r, uint8_t status_g, uint8_t status_b,
                        int weather_valid, int weather_code,
                        int weather_temp, int weather_hi, int weather_lo, int weather_feels,
                        char weather_unit, const char *weather_city,
                        float t, uint16_t *out, int out_len);

#ifdef __cplusplus
}
#endif

#endif
