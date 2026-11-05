/* Wisp core: message header and the table-driven payload codec.
 * MIT License, Wisp contributors. */
#include <string.h>

#include "wisp/msg.h"
#include "wisp/msgs.h"

int wisp_hdr_decode(const uint8_t *body, size_t len, wisp_hdr *h) {
    if (len < WISP_MSG_HDR) return WISP_E_MALFORMED;
    h->op = body[0];
    h->mflags = body[1];
    h->req = wisp_get16(body + 2);
    return WISP_MSG_HDR;
}

void wisp_hdr_encode(uint8_t *out, const wisp_hdr *h) {
    out[0] = h->op;
    out[1] = h->mflags;
    wisp_put16(out + 2, h->req);
}

/* Wire size of a fixed field; 0 for tails. */
static size_t field_size(uint8_t type) {
    switch (type) {
    case WISP_T_U8: case WISP_T_I8: return 1;
    case WISP_T_U16: case WISP_T_I16: return 2;
    case WISP_T_U32: case WISP_T_I32: return 4;
    case WISP_T_U64: return 8;
    case WISP_T_STR16: case WISP_T_HASH16: return 16;
    case WISP_T_SHA256: return 32;
    default: return 0;
    }
}

int wisp_pack(const wisp_desc *d, const void *msg, uint8_t *out, size_t cap) {
    const uint8_t *s = msg;
    size_t n = 0;
    for (unsigned i = 0; i < d->nfields; i++) {
        const wisp_field *f = &d->fields[i];
        const uint8_t *v = s + f->offset;
        size_t size = field_size(f->type);
        const wisp_bytes *tail = (const wisp_bytes *)(const void *)v;
        if (!size) size = tail->len;
        if (cap - n < size) return WISP_E_SPACE;
        uint8_t *o = out + n;
        switch (f->type) {
        case WISP_T_U8: case WISP_T_I8: *o = *v; break;
        case WISP_T_U16: case WISP_T_I16: { uint16_t x; memcpy(&x, v, 2); wisp_put16(o, x); break; }
        case WISP_T_U32: case WISP_T_I32: { uint32_t x; memcpy(&x, v, 4); wisp_put32(o, x); break; }
        case WISP_T_U64: { uint64_t x; memcpy(&x, v, 8); wisp_put64(o, x); break; }
        case WISP_T_STR16: {
            size_t k = 0;
            while (k < 16 && v[k]) k++;
            memcpy(o, v, k);
            memset(o + k, 0, 16 - k);
            break;
        }
        default: if (size) memcpy(o, f->type <= WISP_T_SHA256 ? v : tail->data, size); break;
        }
        n += size;
    }
    return (int)n;
}

int wisp_unpack(const wisp_desc *d, const uint8_t *in, size_t len, void *msg) {
    uint8_t *s = msg;
    size_t n = 0;
    memset(s, 0, d->struct_size);
    for (unsigned i = 0; i < d->nfields && n < len; i++) {
        const wisp_field *f = &d->fields[i];
        uint8_t *v = s + f->offset;
        const uint8_t *p = in + n;
        size_t size = field_size(f->type);
        if (!size) {
            wisp_bytes tail = {p, len - n};
            memcpy(v, &tail, sizeof tail);
            break;
        }
        if (len - n < size) return WISP_E_MALFORMED;
        switch (f->type) {
        case WISP_T_U8: case WISP_T_I8: *v = *p; break;
        case WISP_T_U16: case WISP_T_I16: { uint16_t x = wisp_get16(p); memcpy(v, &x, 2); break; }
        case WISP_T_U32: case WISP_T_I32: { uint32_t x = wisp_get32(p); memcpy(v, &x, 4); break; }
        case WISP_T_U64: { uint64_t x = wisp_get64(p); memcpy(v, &x, 8); break; }
        default: memcpy(v, p, size); break; /* str16 keeps its 17th byte 0 from the memset */
        }
        n += size;
    }
    return WISP_OK;
}

int wisp_msg_encode(uint8_t *out, size_t cap, const wisp_hdr *h, const wisp_desc *d, const void *msg) {
    if (cap < WISP_MSG_HDR) return WISP_E_SPACE;
    wisp_hdr_encode(out, h);
    if (!d) return WISP_MSG_HDR;
    int n = wisp_pack(d, msg, out + WISP_MSG_HDR, cap - WISP_MSG_HDR);
    return n < 0 ? n : n + (int)WISP_MSG_HDR;
}

int wisp_msg_error(uint8_t *out, size_t cap, uint8_t op, uint16_t req, uint16_t code, const char *message) {
    wisp_hdr h = {op, WISP_MF_RESPONSE | WISP_MF_ERROR, req};
    wisp_error_t e = {code, {(const uint8_t *)message, 0}};
    while (message && message[e.message.len]) e.message.len++;
    return wisp_msg_encode(out, cap, &h, &wisp_error_desc, &e);
}

const wisp_desc *wisp_desc_find(uint8_t svc, uint8_t op, uint8_t mflags) {
    if (mflags & WISP_MF_ERROR) return &wisp_error_desc;
    uint8_t kind = (mflags & WISP_MF_EVENT) ? WISP_KIND_EVT : (mflags & WISP_MF_RESPONSE) ? WISP_KIND_RSP : WISP_KIND_REQ;
    for (size_t i = 0; i < wisp_msg_table_len; i++) {
        const wisp_desc *d = wisp_msg_table[i];
        if (d->svc == svc && d->op == op && d->kind == kind) return d;
    }
    return NULL;
}

size_t wisp_items_count(const wisp_desc *item, wisp_bytes items) { return items.len / item->fixed_size; }

int wisp_items_get(const wisp_desc *item, wisp_bytes items, size_t i, void *out) {
    if (i >= wisp_items_count(item, items)) return WISP_E_ARG;
    return wisp_unpack(item, items.data + i * item->fixed_size, item->fixed_size, out);
}
