/* Wisp core: touch input and the gesture recognizer. MIT License, Wisp contributors.
 *
 * The HAL feeds raw touch (down / move / up with a 1-D position along the
 * temple). With gestures enabled the recognizer turns it into tap, double
 * tap, long press start / end and swipes; a single tap is reported once the
 * double-tap gap has passed. Timing comes from INPUT CONFIG (0 = defaults). */
#ifndef WISP_INPUT_H
#define WISP_INPUT_H

#include "msgs.h"

enum { WISP_INPUT_RAW = 1, WISP_INPUT_GESTURES = 2 };
enum { WISP_TOUCH_DOWN = 0, WISP_TOUCH_MOVE = 1, WISP_TOUCH_UP = 2 };
enum {
    WISP_GESTURE_TAP = 1,
    WISP_GESTURE_DOUBLE_TAP = 2,
    WISP_GESTURE_LONG_START = 3,
    WISP_GESTURE_LONG_END = 4,
    WISP_GESTURE_SWIPE_FORWARD = 5,
    WISP_GESTURE_SWIPE_BACK = 6,
};
#define WISP_TAP_MAX_MS_DEFAULT 300u
#define WISP_DOUBLE_GAP_MS_DEFAULT 250u
#define WISP_LONG_MS_DEFAULT 600u
#define WISP_INPUT_PADS 2u

typedef struct {
    bool down, long_sent, tap_pending;
    uint16_t pos0, pos;
    uint64_t t_down, t_tap;
} wisp_pad;

typedef struct {
    uint8_t mask;
    uint16_t tap_max_ms, double_gap_ms, long_ms;
    uint16_t swipe_min; /* position travel that makes a swipe */
    wisp_pad pads[WISP_INPUT_PADS];
} wisp_input;

typedef void (*wisp_gesture_fn)(void *ctx, uint8_t pad, uint8_t kind, uint64_t t_us);

void wisp_input_init(wisp_input *in, uint16_t swipe_min);
void wisp_input_config(wisp_input *in, const wisp_input_config_req_t *m);
void wisp_input_touch(wisp_input *in, uint8_t pad, uint8_t phase, uint16_t pos, uint64_t t_us, wisp_gesture_fn fn,
                      void *ctx);
/* Long presses and delayed single taps. */
void wisp_input_tick(wisp_input *in, uint64_t now_us, wisp_gesture_fn fn, void *ctx);

#endif
