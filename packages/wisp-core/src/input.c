/* Wisp core: touch input and the gesture recognizer. MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/input.h"

void wisp_input_init(wisp_input *in, uint16_t swipe_min) {
    memset(in, 0, sizeof *in);
    in->swipe_min = swipe_min ? swipe_min : 1;
    wisp_input_config_req_t none = {0, 0, 0, 0};
    wisp_input_config(in, &none);
}

void wisp_input_config(wisp_input *in, const wisp_input_config_req_t *m) {
    in->mask = m->mask & (WISP_INPUT_RAW | WISP_INPUT_GESTURES);
    in->tap_max_ms = m->tap_max_ms ? m->tap_max_ms : WISP_TAP_MAX_MS_DEFAULT;
    in->double_gap_ms = m->double_gap_ms ? m->double_gap_ms : WISP_DOUBLE_GAP_MS_DEFAULT;
    in->long_ms = m->long_ms ? m->long_ms : WISP_LONG_MS_DEFAULT;
    memset(in->pads, 0, sizeof in->pads);
}

static uint16_t travel(const wisp_pad *p) { return (uint16_t)(p->pos > p->pos0 ? p->pos - p->pos0 : p->pos0 - p->pos); }

void wisp_input_touch(wisp_input *in, uint8_t pad, uint8_t phase, uint16_t pos, uint64_t t, wisp_gesture_fn fn,
                      void *ctx) {
    if (pad >= WISP_INPUT_PADS || !(in->mask & WISP_INPUT_GESTURES)) return;
    wisp_pad *p = &in->pads[pad];
    switch (phase) {
    case WISP_TOUCH_DOWN:
        wisp_input_tick(in, t, fn, ctx);
        p->down = true;
        p->long_sent = false;
        p->pos0 = p->pos = pos;
        p->t_down = t;
        break;
    case WISP_TOUCH_MOVE:
        if (p->down) p->pos = pos;
        break;
    case WISP_TOUCH_UP: {
        if (!p->down) break;
        p->pos = pos;
        p->down = false;
        uint64_t held = t - p->t_down;
        if (p->long_sent) {
            fn(ctx, pad, WISP_GESTURE_LONG_END, t);
        } else if (travel(p) >= in->swipe_min) {
            p->tap_pending = false;
            fn(ctx, pad, p->pos > p->pos0 ? WISP_GESTURE_SWIPE_FORWARD : WISP_GESTURE_SWIPE_BACK, t);
        } else if (held >= (uint64_t)in->long_ms * 1000u) {
            fn(ctx, pad, WISP_GESTURE_LONG_START, p->t_down + (uint64_t)in->long_ms * 1000u);
            fn(ctx, pad, WISP_GESTURE_LONG_END, t);
        } else if (held <= (uint64_t)in->tap_max_ms * 1000u) {
            if (p->tap_pending) {
                p->tap_pending = false;
                fn(ctx, pad, WISP_GESTURE_DOUBLE_TAP, t);
            } else {
                p->tap_pending = true;
                p->t_tap = t;
            }
        }
        break;
    }
    default: break;
    }
}

void wisp_input_tick(wisp_input *in, uint64_t now, wisp_gesture_fn fn, void *ctx) {
    if (!(in->mask & WISP_INPUT_GESTURES)) return;
    for (uint8_t i = 0; i < WISP_INPUT_PADS; i++) {
        wisp_pad *p = &in->pads[i];
        if (p->tap_pending && !p->down && now - p->t_tap >= (uint64_t)in->double_gap_ms * 1000u) {
            p->tap_pending = false;
            fn(ctx, i, WISP_GESTURE_TAP, p->t_tap);
        }
        if (p->down && !p->long_sent && travel(p) < in->swipe_min &&
            now - p->t_down >= (uint64_t)in->long_ms * 1000u) {
            p->long_sent = true;
            p->tap_pending = false;
            fn(ctx, i, WISP_GESTURE_LONG_START, now);
        }
    }
}
