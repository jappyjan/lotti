/* Wisp core: the glasses-side engine. MIT License, Wisp contributors.
 *
 * Ties the session to the display, resource, input, sensor (wear) and system
 * services: feed it every received message body, call tick regularly, and it
 * answers through the HAL. Everything lives in one caller-provided arena
 * sized by wisp_engine_arena_size(); nothing is allocated elsewhere.
 *
 *   arena: [display tables + strip] [resource table] [players] [tweens] [reply buffer]
 *          [resource pool: res_bytes] [graphics pool: gfx_bytes, layer buffers + temporaries]
 *
 * One engine is one lens. Framing and flow control stay with the caller
 * (wisp_rx / wisp_tx); the engine works on message bodies. */
#ifndef WISP_ENGINE_H
#define WISP_ENGINE_H

#include "anim.h"
#include "display.h"
#include "input.h"
#include "resource.h"
#include "session.h"

/* caps bits (protocol.md, HELLO) */
enum {
    WISP_CAP_DISPLAY = 1u << 0,
    WISP_CAP_ANIMATION = 1u << 1,
    WISP_CAP_TWEEN = 1u << 2,
    WISP_CAP_TEXT = 1u << 3,
    WISP_CAP_PERSIST = 1u << 4,
    WISP_CAP_TOUCH_RAW = 1u << 5,
    WISP_CAP_GESTURES = 1u << 6,
    WISP_CAP_WEAR = 1u << 10,
    WISP_CAP_FORWARD = 1u << 16,
    WISP_CAP_RLE4 = 1u << 17,
    WISP_CAP_LZ4 = 1u << 18,
    WISP_CAP_DELTA = 1u << 19,
};

enum { WISP_SENSOR_WEAR = 5 };

typedef struct {
    void *ctx;
    /* Composed rows for the panel (required). */
    wisp_present_fn present;
    /* After the last strip of a frame (optional): flush / swap. */
    void (*frame_done)(void *ctx, uint32_t frame);
    /* An outgoing message body (response or event) for the link (required). */
    void (*send)(void *ctx, uint8_t svc, const uint8_t *body, size_t len);
    void (*display_power)(void *ctx, bool on);                  /* optional */
    void (*brightness)(void *ctx, uint8_t mode, uint8_t level); /* optional */
    const wisp_storage *storage;                                /* optional: no persist cap without it */
} wisp_hal;

typedef struct {
    const char *fw_name, *fw_version, *hw_rev, *serial;
    uint8_t lens; /* 1 left, 2 right */
    uint16_t canvas_w, canvas_h;
    uint8_t max_layers, anim_slots, tween_slots;
    uint16_t max_res;
    uint32_t res_bytes, gfx_bytes;
    uint16_t strip_rows;
    uint16_t max_frame;
    uint32_t rx_window, session_timeout_ms;
    uint16_t swipe_min;  /* touch travel for a swipe, in pos units */
    uint32_t extra_caps; /* e.g. WISP_CAP_FORWARD, set by the HAL */
} wisp_engine_config;

typedef struct {
    uint32_t msgs, errors, auto_frames;
    uint32_t rx_bytes, tx_bytes;
} wisp_engine_stats;

typedef struct {
    wisp_engine_config cfg;
    wisp_hal hal;
    wisp_session_hello_rsp_t hello;
    wisp_session session;
    wisp_display display;
    wisp_pool gfx;
    wisp_resources res;
    wisp_anim *anims;
    wisp_tween *tweens;
    wisp_input input;
    wisp_dirty auto_dirty;
    uint8_t app;
    uint8_t *out;
    size_t out_cap;
    bool worn, power_on, off_when_unworn, display_on, wear_sub;
    uint64_t now_us;
    wisp_engine_stats stats;
} wisp_engine;

/* A config with the G2 defaults (640×480, 16 layers, …); adjust and pass to init. */
void wisp_engine_defaults(wisp_engine_config *c);
size_t wisp_engine_arena_size(const wisp_engine_config *c);
/* Returns WISP_OK, or WISP_E_ARG / WISP_E_SPACE (arena too small). */
int wisp_engine_init(wisp_engine *e, const wisp_engine_config *c, const wisp_hal *hal, void *arena, size_t size);

/* One received message body. r tells the caller about CREDIT / RESYNC / session start and end. */
void wisp_engine_rx(wisp_engine *e, uint8_t svc, const uint8_t *body, size_t len, uint64_t now_us,
                    wisp_session_result *r);
/* Animations, tweens (with their auto-commit), gesture timers, session timeout. Returns true when the
 * session timed out. Call every few ms while anything runs. */
bool wisp_engine_tick(wisp_engine *e, uint64_t now_us);
/* True while animations, tweens or gesture timers want ticks. */
bool wisp_engine_busy(const wisp_engine *e);

/* From the HAL's sensors. */
void wisp_engine_touch(wisp_engine *e, uint8_t pad, uint8_t phase, uint16_t pos, uint64_t now_us);
/* A gesture recognised elsewhere (e.g. by the touch controller). */
void wisp_engine_gesture(wisp_engine *e, uint8_t pad, uint8_t kind, uint64_t now_us);
void wisp_engine_set_worn(wisp_engine *e, bool worn, uint64_t now_us);

#endif
