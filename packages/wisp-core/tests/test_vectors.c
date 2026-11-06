/* Checks the C core against every golden vector in packages/wisp-proto/vectors.
 * usage: test_vectors <vectors dir> */
#include <dirent.h>
#include <stdalign.h>
#include <string.h>

#include "json.h"
#include "test.h"
#include "wisp/codec.h"
#include "wisp/crc.h"
#include "wisp/frame.h"
#include "wisp/msgs.h"

static const char *case_name;
static int cases, failed_cases;

static void fail(const char *what) {
    fprintf(stderr, "FAIL %s: %s\n", case_name, what);
    test_failures++;
}

static const char *str(const jv *c, const char *key) {
    const jv *v = json_get(c, key);
    return v && v->type == J_STR ? v->str : "";
}
static double num(const jv *c, const char *key) {
    const jv *v = json_get(c, key);
    return v ? v->num : -1;
}
static bool flag(const jv *c, const char *key) {
    const jv *v = json_get(c, key);
    return v && v->num;
}

static uint8_t arena[1 << 16];
static size_t arena_used;

static uint8_t *hex_alloc(const char *hex, size_t *len) {
    uint8_t *p = arena + arena_used;
    *len = from_hex(hex, p, sizeof arena - arena_used);
    arena_used += *len;
    return p;
}

static bool hex_eq(const uint8_t *data, size_t len, const char *hex) {
    uint8_t want[8192];
    size_t n = from_hex(hex, want, sizeof want);
    return n == len && (!len || !memcmp(want, data, len));
}

/* ---- crc ---- */

static void test_crc(const jv *c) {
    uint8_t in[512], out[4];
    size_t n = from_hex(str(c, "input_hex"), in, sizeof in);
    const char *algo = str(c, "algo");
    if (!strcmp(algo, "crc16-ccitt-false")) {
        wisp_put16(out, wisp_crc16(WISP_CRC16_INIT, in, n));
        if (!hex_eq(out, 2, str(c, "hex"))) fail("crc16");
    } else if (!strcmp(algo, "crc32c-msb")) {
        wisp_put32(out, wisp_crc32c_msb(WISP_CRC32C_MSB_INIT, in, n));
        if (!hex_eq(out, 4, str(c, "hex"))) fail("crc32c-msb");
    } else if (!strcmp(algo, "crc32-zlib")) {
        wisp_put32(out, wisp_crc32(0, in, n));
        if (!hex_eq(out, 4, str(c, "hex"))) fail("crc32-zlib");
    } else {
        fail("unknown algo");
    }
}

/* ---- frames, streams ---- */

static void test_frame(const jv *c) {
    uint8_t body[8192], out[8192], buf[WISP_MAX_FRAME_DEFAULT + WISP_FRAME_OVERHEAD];
    size_t n = from_hex(str(c, "body_hex"), body, sizeof body);
    uint16_t seq = (uint16_t)num(c, "seq");
    uint8_t fflags = (uint8_t)num(c, "fflags");
    int len = wisp_frame_encode(out, sizeof out, (uint8_t)num(c, "svc"), (uint8_t)num(c, "route"), fflags, seq, body, n);
    if (len < 0 || !hex_eq(out, (size_t)len, str(c, "hex"))) return fail("encode");

    wisp_rx rx;
    wisp_rx_event ev;
    wisp_frame f;
    wisp_rx_init(&rx, buf, sizeof buf);
    rx.last_good_seq = (uint16_t)(seq - 1u);
    size_t used = wisp_rx_feed(&rx, out, (size_t)len, &ev, &f);
    if (ev != ((fflags & WISP_FF_CTRL) ? WISP_RX_CONTROL : WISP_RX_FRAME) || used != (size_t)len || f.seq != seq ||
        f.svc != num(c, "svc") || f.route != num(c, "route") || f.fflags != fflags || f.len != n ||
        memcmp(f.body, body, n))
        fail("decode");
}

/* The next expected item of a vector array (hex strings or numbers). */
static bool next_hex(const jv *arr, size_t *i, const wisp_frame *f) {
    return arr && *i < arr->n && hex_eq(f->body - WISP_FRAME_HDR, f->len + WISP_FRAME_OVERHEAD, arr->items[(*i)++].str);
}
static bool next_num(const jv *arr, size_t *i, double v) { return arr && *i < arr->n && arr->items[(*i)++].num == v; }
static size_t len_of(const jv *arr) { return arr ? arr->n : 0; }

static void test_stream(const jv *c) {
    uint8_t buf[WISP_MAX_FRAME_DEFAULT + WISP_FRAME_OVERHEAD], chunk[8192];
    const jv *chunks = json_get(c, "chunks"), *frames = json_get(c, "frames"), *resyncs = json_get(c, "resyncs"),
             *controls = json_get(c, "controls"), *credits = json_get(c, "credits");
    size_t nframes = 0, nresyncs = 0, ncontrols = 0, ncredits = 0;
    wisp_rx rx;
    wisp_rx_init(&rx, buf, sizeof buf);
    for (size_t i = 0; i < chunks->n; i++) {
        size_t len = from_hex(chunks->items[i].str, chunk, sizeof chunk);
        const uint8_t *p = chunk;
        wisp_rx_event ev;
        wisp_frame f;
        do {
            size_t used = wisp_rx_feed(&rx, p, len, &ev, &f);
            p += used;
            len -= used;
            if (ev == WISP_RX_FRAME && !next_hex(frames, &nframes, &f)) fail("unexpected frame");
            if (ev == WISP_RX_CONTROL && !next_hex(controls, &ncontrols, &f)) fail("unexpected control frame");
            if (ev == WISP_RX_RESYNC && !next_num(resyncs, &nresyncs, rx.last_good_seq)) fail("unexpected resync");
            if (ev == WISP_RX_DUPLICATE && !next_num(credits, &ncredits, rx.last_good_seq)) fail("unexpected credit");
        } while (ev != WISP_RX_NONE);
    }
    if (nframes != len_of(frames)) fail("missing frames");
    if (nresyncs != len_of(resyncs)) fail("missing resyncs");
    if (ncontrols != len_of(controls)) fail("missing control frames");
    if (ncredits != len_of(credits)) fail("missing credits");
}

/* ---- messages ---- */

static const wisp_field *find_field(const wisp_desc *d, const char *name) {
    for (unsigned i = 0; i < d->nfields; i++)
        if (!strcmp(d->fields[i].name, name)) return &d->fields[i];
    return NULL;
}

static bool is_int(uint8_t t) { return t <= WISP_T_U64; }

static int64_t get_int(uint8_t t, const uint8_t *v) {
    switch (t) {
    case WISP_T_U8: return *v;
    case WISP_T_I8: return (int8_t)*v;
    case WISP_T_U16: { uint16_t x; memcpy(&x, v, 2); return x; }
    case WISP_T_I16: { int16_t x; memcpy(&x, v, 2); return x; }
    case WISP_T_U32: { uint32_t x; memcpy(&x, v, 4); return x; }
    case WISP_T_I32: { int32_t x; memcpy(&x, v, 4); return x; }
    default: { uint64_t x; memcpy(&x, v, 8); return (int64_t)x; }
    }
}

static void set_int(uint8_t t, uint8_t *v, int64_t x) {
    switch (t) {
    case WISP_T_U8: case WISP_T_I8: *v = (uint8_t)x; break;
    case WISP_T_U16: case WISP_T_I16: { uint16_t y = (uint16_t)x; memcpy(v, &y, 2); break; }
    case WISP_T_U32: case WISP_T_I32: { uint32_t y = (uint32_t)x; memcpy(v, &y, 4); break; }
    default: { uint64_t y = (uint64_t)x; memcpy(v, &y, 8); break; }
    }
}

static size_t fixed_bytes(uint8_t t) { return t == WISP_T_SHA256 ? 32 : 16; }

/* The decoded struct `s` must equal the vector's fields. */
static void compare(const wisp_desc *d, const uint8_t *s, const jv *fields) {
    for (size_t i = 0; i < fields->n; i++)
        if (!find_field(d, fields->keys[i])) fail("vector has a field the table doesn't");
    for (unsigned i = 0; i < d->nfields; i++) {
        const wisp_field *f = &d->fields[i];
        const jv *j = json_get(fields, f->name);
        const uint8_t *v = s + f->offset;
        const wisp_bytes *b = (const wisp_bytes *)(const void *)v;
        if (!j) {
            fail("field missing in vector");
        } else if (is_int(f->type)) {
            if (get_int(f->type, v) != (int64_t)j->num) fail(f->name);
        } else if (f->type == WISP_T_STR16) {
            if (strcmp((const char *)v, j->str)) fail(f->name);
        } else if (f->type == WISP_T_HASH16 || f->type == WISP_T_SHA256) {
            if (!hex_eq(v, fixed_bytes(f->type), j->str)) fail(f->name);
        } else if (f->type == WISP_T_BYTES) {
            if (!hex_eq(b->data, b->len, j->str)) fail(f->name);
        } else if (f->type == WISP_T_UTF8) {
            if (b->len != strlen(j->str) || (b->len && memcmp(b->data, j->str, b->len))) fail(f->name);
        } else if (f->type == WISP_T_ITEMS) {
            size_t count = wisp_list_count(d, s, f);
            if (count != j->n) fail("item count");
            for (size_t k = 0; k < j->n && k < count; k++) {
                alignas(16) uint8_t item[256];
                if (wisp_items_get(f->item, *b, count, k, item) < 0) fail("item unpack");
                compare(f->item, item, &j->items[k]);
            }
        }
    }
}

/* Fills struct `s` from the vector's fields; tails live in the arena. */
static void build(const wisp_desc *d, const jv *fields, uint8_t *s) {
    memset(s, 0, d->struct_size);
    for (unsigned i = 0; i < d->nfields; i++) {
        const wisp_field *f = &d->fields[i];
        const jv *j = json_get(fields, f->name);
        uint8_t *v = s + f->offset;
        wisp_bytes b = {0};
        if (!j) continue;
        if (is_int(f->type)) {
            set_int(f->type, v, (int64_t)j->num);
        } else if (f->type == WISP_T_STR16) {
            strncpy((char *)v, j->str, 16);
        } else if (f->type == WISP_T_HASH16 || f->type == WISP_T_SHA256) {
            from_hex(j->str, v, fixed_bytes(f->type));
        } else if (f->type == WISP_T_BYTES) {
            b.data = hex_alloc(j->str, &b.len);
        } else if (f->type == WISP_T_UTF8) {
            b.data = (const uint8_t *)j->str;
            b.len = strlen(j->str);
        } else if (f->type == WISP_T_ITEMS) {
            b.data = arena + arena_used;
            for (size_t k = 0; k < j->n; k++) {
                alignas(16) uint8_t item[256];
                build(f->item, &j->items[k], item);
                int n = wisp_pack(f->item, item, arena + arena_used, sizeof arena - arena_used);
                arena_used += n > 0 ? (size_t)n : 0;
            }
            b.len = (size_t)(arena + arena_used - b.data);
        }
        if (f->type >= WISP_T_BYTES) memcpy(v, &b, sizeof b);
    }
}

static void test_message(const jv *c) {
    uint8_t body[8192], out[8192];
    alignas(16) uint8_t s[1024];
    size_t len = from_hex(str(c, "hex"), body, sizeof body);
    const jv *fields = json_get(c, "fields");
    wisp_hdr h;
    if (wisp_hdr_decode(body, len, &h) < 0) return fail("header");
    if (h.op != num(c, "op") || h.mflags != num(c, "mflags") || h.req != num(c, "req")) fail("header fields");
    const wisp_desc *d = wisp_desc_find((uint8_t)num(c, "svc"), h.op, h.mflags);
    if (!d) return fail("no layout for (svc, op, mflags)");
    int r = wisp_unpack(d, body + WISP_MSG_HDR, len - WISP_MSG_HDR, s);
    if (flag(c, "malformed")) {
        if (r != WISP_E_MALFORMED) fail("malformed payload accepted");
        return;
    }
    if (r < 0) return fail("unpack");
    compare(d, s, fields);

    if (flag(c, "decode_only")) return;
    build(d, fields, s);
    int n = wisp_msg_encode(out, sizeof out, &h, d, s);
    if (n < 0 || !hex_eq(out, (size_t)n, str(c, "hex"))) fail("encode");
}

/* ---- codecs ---- */

static void test_codec(const jv *c) {
    static uint8_t in[16384], pixels[16384], out[16384], tmp[16384], scratch[16384];
    static uint32_t table[WISP_LZ4_TABLE];
    uint8_t codec = (uint8_t)num(c, "codec");
    uint16_t w = (uint16_t)num(c, "w"), h = (uint16_t)num(c, "h");
    size_t len = from_hex(str(c, "hex"), in, sizeof in);
    if (flag(c, "malformed")) {
        if (wisp_pixels_decode(codec, in, len, w, h, out, sizeof out, scratch, sizeof scratch) != WISP_E_MALFORMED)
            fail("malformed data accepted");
        return;
    }
    size_t npix = from_hex(str(c, "pixels_hex"), pixels, sizeof pixels);
    if (npix != wisp_raw4_size(w, h)) return fail("pixels_hex size");

    int n = wisp_pixels_decode(codec, in, len, w, h, out, sizeof out, scratch, sizeof scratch);
    if (n != (int)npix || memcmp(out, pixels, npix)) fail("decode");

    /* Encode: byte-exact unless decode_only, then our encoder must round-trip. */
    int rle = 0;
    switch (codec) {
    case WISP_CODEC_RAW4: memcpy(tmp, pixels, npix); n = (int)npix; break;
    case WISP_CODEC_RLE4: n = wisp_rle4_encode(pixels, w, h, tmp, sizeof tmp); break;
    case WISP_CODEC_LZ4: n = wisp_lz4_encode(pixels, npix, tmp, sizeof tmp, table); break;
    case WISP_CODEC_LZ4_RLE:
        rle = wisp_rle4_encode(pixels, w, h, scratch, sizeof scratch);
        n = rle < 0 ? rle : wisp_lz4_encode(scratch, (size_t)rle, tmp, sizeof tmp, table);
        break;
    }
    if (n < 0) return fail("encode");
    if (!flag(c, "decode_only") && !hex_eq(tmp, (size_t)n, str(c, "hex"))) fail("encode bytes");
    int m = wisp_pixels_decode(codec, tmp, (size_t)n, w, h, out, sizeof out, scratch, sizeof scratch);
    if (m != (int)npix || memcmp(out, pixels, npix)) fail("round trip");
}

static void run_file(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        fprintf(stderr, "cannot open %s\n", path);
        test_failures++;
        return;
    }
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    char *text = malloc((size_t)size + 1);
    text[fread(text, 1, (size_t)size, fp)] = 0;
    fclose(fp);
    jv *root = json_parse(text);
    if (!root || root->type != J_ARR) {
        fprintf(stderr, "%s: not a JSON array\n", path);
        test_failures++;
        json_free(root);
        free(text);
        return;
    }
    for (size_t i = 0; i < root->n; i++) {
        const jv *c = &root->items[i];
        const char *kind = str(c, "kind");
        int before = test_failures;
        case_name = str(c, "name");
        arena_used = 0;
        if (!strcmp(kind, "crc")) test_crc(c);
        else if (!strcmp(kind, "frame")) test_frame(c);
        else if (!strcmp(kind, "stream")) test_stream(c);
        else if (!strcmp(kind, "message")) test_message(c);
        else if (!strcmp(kind, "codec")) test_codec(c);
        else fail("unknown kind");
        cases++;
        failed_cases += test_failures != before;
    }
    json_free(root);
    free(text);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <vectors dir>\n", argv[0]);
        return 2;
    }
    DIR *dir = opendir(argv[1]);
    if (!dir) {
        perror(argv[1]);
        return 2;
    }
    struct dirent *e;
    int files = 0;
    while ((e = readdir(dir))) {
        size_t n = strlen(e->d_name);
        if (n < 5 || strcmp(e->d_name + n - 5, ".json")) continue;
        char path[4096];
        snprintf(path, sizeof path, "%s/%s", argv[1], e->d_name);
        run_file(path);
        files++;
    }
    closedir(dir);
    printf("vectors: %d files, %d cases, %d failed\n", files, cases, failed_cases);
    return files && !test_failures ? 0 : 1;
}
