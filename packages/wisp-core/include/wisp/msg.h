/* Wisp core: message header and the table-driven payload codec.
 * MIT License, Wisp contributors.
 *
 * Body = op u8, mflags u8, req u16, payload. Each payload layout is a
 * wisp_desc (generated into msgs.h from tools/spec.py) describing a C struct.
 * Append-only rule: unpacking ignores trailing bytes it doesn't know and
 * leaves missing trailing fields at 0. */
#ifndef WISP_MSG_H
#define WISP_MSG_H

#include "common.h"

#define WISP_MSG_HDR 4u

enum { WISP_MF_RESPONSE = 1, WISP_MF_ERROR = 2, WISP_MF_EVENT = 4 };

/* ERROR response codes */
enum {
    WISP_ERR_UNSUPPORTED = 1,
    WISP_ERR_BAD_PAYLOAD = 2,
    WISP_ERR_NO_SUCH_ID = 3,
    WISP_ERR_NO_MEMORY = 4,
    WISP_ERR_BUSY = 5,
    WISP_ERR_HASH_MISMATCH = 6,
    WISP_ERR_NOT_ALLOWED = 7,
    WISP_ERR_EXISTS = 8,
};

typedef struct {
    uint8_t op, mflags;
    uint16_t req;
} wisp_hdr;

/* Returns WISP_MSG_HDR, or WISP_E_MALFORMED if the body is shorter than a header. */
int wisp_hdr_decode(const uint8_t *body, size_t len, wisp_hdr *h);
void wisp_hdr_encode(uint8_t *out, const wisp_hdr *h);

typedef enum {
    WISP_T_U8, WISP_T_I8, WISP_T_U16, WISP_T_I16, WISP_T_U32, WISP_T_I32, WISP_T_U64,
    WISP_T_STR16,  /* char[17]: up to 16 bytes, NUL-terminated after unpack */
    WISP_T_HASH16, /* uint8_t[16] */
    WISP_T_SHA256, /* uint8_t[32] */
    WISP_T_BYTES,  /* wisp_bytes tail: rest of the payload */
    WISP_T_UTF8,   /* wisp_bytes tail, UTF-8 text */
    WISP_T_ITEMS,  /* wisp_bytes tail: fixed-size structs described by `item` */
} wisp_ftype;

enum { WISP_KIND_REQ, WISP_KIND_RSP, WISP_KIND_EVT, WISP_KIND_ERR, WISP_KIND_STRUCT };

typedef struct wisp_desc wisp_desc;

typedef struct {
    const char *name;
    uint8_t type;      /* wisp_ftype */
    uint16_t offset;   /* in the C struct */
    const wisp_desc *item;
} wisp_field;

struct wisp_desc {
    const char *name;  /* "session/hello" */
    uint8_t svc, op, kind;
    uint8_t nfields;
    uint16_t fixed_size;  /* wire bytes before the tail */
    uint16_t struct_size; /* sizeof the C struct */
    const wisp_field *fields;
};

/* Every message layout (generated), for wisp_desc_find and generic tools. */
extern const wisp_desc *const wisp_msg_table[];
extern const size_t wisp_msg_table_len;

/* Payload only (no header). Returns its length or WISP_E_SPACE. */
int wisp_pack(const wisp_desc *d, const void *msg, uint8_t *out, size_t cap);
/* Returns WISP_OK or WISP_E_MALFORMED (a field cut in half). Tails borrow from `in`. */
int wisp_unpack(const wisp_desc *d, const uint8_t *in, size_t len, void *msg);

/* Header + payload. `d` may be NULL for an empty payload. Returns the body length. */
int wisp_msg_encode(uint8_t *out, size_t cap, const wisp_hdr *h, const wisp_desc *d, const void *msg);
/* ERROR response to (op, req) with an optional message (may be NULL). */
int wisp_msg_error(uint8_t *out, size_t cap, uint8_t op, uint16_t req, uint16_t code, const char *message);

/* The payload layout for a message: ERROR, EVENT and RESPONSE pick the kind. NULL = empty payload. */
const wisp_desc *wisp_desc_find(uint8_t svc, uint8_t op, uint8_t mflags);

/* Items tails: number of whole items, and unpacking item i. */
size_t wisp_items_count(const wisp_desc *item, wisp_bytes items);
int wisp_items_get(const wisp_desc *item, wisp_bytes items, size_t i, void *out);

#endif
