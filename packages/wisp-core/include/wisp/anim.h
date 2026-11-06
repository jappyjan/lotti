/* Wisp core: animation players and tweens. MIT License, Wisp contributors.
 *
 * Both run on wisp_engine_tick(now_us) and cost no radio traffic per frame.
 * A player decodes an animation resource frame by frame (key frames, XOR
 * delta frames against the previous frame, per-frame durations, loops) into
 * its own frame buffer and copies each frame into its layer. A tween moves
 * one layer property towards a target with an easing curve. Damage goes to
 * the display's current sink, so the engine can auto-commit just that. */
#ifndef WISP_ANIM_H
#define WISP_ANIM_H

#include "display.h"
#include "resource.h"

typedef struct {
    bool active;
    uint8_t app, layer;
    int16_t x, y;
    uint16_t res, loops, loop, frame, w, h;
    uint32_t pos;     /* offset of the next frame in the resource */
    uint64_t next_us; /* when the next frame is due */
    uint8_t *state;   /* the current frame, RAW4 (display pool) */
} wisp_anim;

/* 0 or a WISP_ERR_* code. Shows frame 0 right away. */
int wisp_anim_play(wisp_anim *a, wisp_resources *r, wisp_display *d, uint8_t app,
                   const wisp_display_anim_play_req_t *m, uint64_t now_us);
void wisp_anim_stop(wisp_anim *a, wisp_resources *r, wisp_display *d);
/* Advances to now; true when it drew. *done when the last loop ended (the player is stopped). */
bool wisp_anim_tick(wisp_anim *a, wisp_resources *r, wisp_display *d, uint64_t now_us, bool *done);

enum { WISP_EASE_LINEAR, WISP_EASE_IN, WISP_EASE_OUT, WISP_EASE_IN_OUT };

typedef struct {
    bool active;
    uint8_t layer, prop, easing;
    int32_t from, to;
    uint64_t t0_us;
    uint32_t dur_us;
} wisp_tween;

/* Eased progress, 0…65536 for t = 0…65536. */
uint32_t wisp_ease(uint8_t easing, uint32_t t);
void wisp_tween_start(wisp_tween *t, const wisp_layer *l, const wisp_display_tween_req_t *m, uint64_t now_us);
/* Applies the value for now; false once finished (and inactive). */
bool wisp_tween_tick(wisp_tween *t, wisp_display *d, uint64_t now_us);

#endif
