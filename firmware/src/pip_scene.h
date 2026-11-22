/* pip_scene.h — the 21-state Pip scene (three typing takes), host/device buildable, no dependencies.
 *
 * Ports research/demo/pip.js: pose easing, blink, typing phase, rings, keyboard,
 * paws, props, labels, particles.  The scene emits into an r_dl (renderer/src/raster.h);
 * it never touches pixels.  One fixed 30 Hz step is the canonical replay rate: call
 * pip_scene_frame() with dt = 1/30 from t = 0 to reproduce a frame exactly.
 *
 * State lives in pip_scene: pose (14 eased scalars), typing phase, seeded flying-key
 * particles.  pip_scene_reset() snaps the pose (research/demo/index.html:198 calls
 * PIP.reset() on every state change), clears phase/particles and reseeds the PRNG.
 * The only randomness is flying-key spawn (pip.js:525-528); the seed makes replay exact.
 */
#ifndef PIP_SCENE_H
#define PIP_SCENE_H

#include <stdbool.h>
#include <stdint.h>

#include "raster.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
  PIP_WORK = 0, PIP_IDLE, PIP_CURIOUS, PIP_THINKING, PIP_SEARCH, PIP_READ,
  PIP_WAIT, PIP_SLEEP, PIP_WAKE, PIP_APPROVAL, PIP_MCQ, PIP_RETRY, PIP_DONE,
  PIP_OFFLINE, PIP_HUB, PIP_WORK_CRAZY, PIP_WORK_ANNOYED,
  PIP_DIZZY, PIP_TOOL_CALL, PIP_RUN_CMD, PIP_STROKED, PIP_NSTATE
};

#define PIP_POSE_N 14
#define PIP_MAX_KEYS 24

extern const char *const pip_state_names[PIP_NSTATE];

typedef struct {
  float battery;            /* 0..100, canvas option (pip.js rings opts) */
  bool charging;            /* charging bolt at the battery arc tip */
  bool rings;               /* false hides both rings (demo option) */
  bool effects;             /* false hides done's orbiting dots only */
  int variant;              /* 0/1; flips the blep tongue side. toolCall picks
                             * its own take randomly on each scene reset. */
  float stroke;             /* -1..1, happy gaze follows where the screen was stroked */
  int njob;                 /* 0..6 subagent arcs; 0 = no arcs (refs show none) */
  int agents;               /* 0..19 agents shown as coloured keyboard keys */
  r_rgb job[6];
  float job_weight[6];      /* target weight, eased by the scene */
  float job_span;           /* target arc fraction of the even slot; 1 = demo */
  float job_spin;           /* target radians/s; scene integrates angle */
  bool has_color;           /* true overrides the per-state palette colour */
  r_rgb color;
  bool has_bg;              /* true overrides the default screen background */
  r_rgb bg;
  const char *text;         /* params.text; NULL = no caption */
} pip_opts;

typedef struct {
  float x, y, vx, vy, a, va, age;   /* flying-key particle (pip.js:524-538) */
} pip_part;

typedef struct {
  uint32_t seed, rng;
  uint32_t take_rng, take;   /* toolCall take; advances on every reset */
  float phase;              /* typing phase, advanced in the three typing states */
  float next_key;           /* next flying-key spawn time */
  float pose[PIP_POSE_N];
  int pose_init;
  int nkey;
  pip_part key[PIP_MAX_KEYS];
  /* ring easing: targets come from pip_opts, the scene eases them. */
  float job_w[6], job_span, job_ang;
  int ring_init;
  r_rgb ink;                /* eased face colour across state changes */
  int ink_init;
} pip_scene;

void pip_scene_init(pip_scene *s, uint32_t seed);
void pip_scene_reset(pip_scene *s);
void pip_opts_default(pip_opts *o);       /* battery 78, 3 jobs, rings/effects on */
r_rgb pip_state_color(int state);

/* Build one frame into dl (call r_dl_reset first) and advance the scene by dt.
 * t is state-local seconds; callers replaying a clip pass t = frame/30. */
int pip_scene_frame(r_dl *dl, pip_scene *s, int state, float t, float dt,
                    const pip_opts *opt);

#ifdef __cplusplus
}
#endif
#endif /* PIP_SCENE_H */
