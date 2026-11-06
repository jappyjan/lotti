/* Minimal JSON reader for the vector tests (allocates; tests only). */
#include "json.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    const char *p;
    int err;
} parser;

static void ws(parser *ps) {
    while (*ps->p == ' ' || *ps->p == '\n' || *ps->p == '\r' || *ps->p == '\t') ps->p++;
}

static void push(jv *v, const jv *item, char *key) {
    v->items = realloc(v->items, (v->n + 1) * sizeof *v->items);
    v->items[v->n] = *item;
    if (v->type == J_OBJ) {
        v->keys = realloc(v->keys, (v->n + 1) * sizeof *v->keys);
        v->keys[v->n] = key;
    }
    v->n++;
}

static size_t put_utf8(char *o, unsigned c) {
    if (c < 0x80) return o[0] = (char)c, 1;
    if (c < 0x800) return o[0] = (char)(0xC0 | c >> 6), o[1] = (char)(0x80 | (c & 0x3F)), 2;
    if (c < 0x10000)
        return o[0] = (char)(0xE0 | c >> 12), o[1] = (char)(0x80 | (c >> 6 & 0x3F)), o[2] = (char)(0x80 | (c & 0x3F)), 3;
    o[0] = (char)(0xF0 | c >> 18), o[1] = (char)(0x80 | (c >> 12 & 0x3F));
    o[2] = (char)(0x80 | (c >> 6 & 0x3F)), o[3] = (char)(0x80 | (c & 0x3F));
    return 4;
}

static char *string(parser *ps) {
    const char *s = ++ps->p; /* past the quote */
    char *out = malloc(strlen(s) + 1), *o = out;
    while (*s && *s != '"') {
        if (*s != '\\') {
            *o++ = *s++;
            continue;
        }
        s++;
        switch (*s) {
        case 'n': *o++ = '\n'; s++; break;
        case 't': *o++ = '\t'; s++; break;
        case 'r': *o++ = '\r'; s++; break;
        case 'b': *o++ = '\b'; s++; break;
        case 'f': *o++ = '\f'; s++; break;
        case 'u': {
            unsigned c = (unsigned)strtoul((char[]){s[1], s[2], s[3], s[4], 0}, NULL, 16);
            s += 5;
            if (c >= 0xD800 && c < 0xDC00 && s[0] == '\\' && s[1] == 'u') {
                unsigned lo = (unsigned)strtoul((char[]){s[2], s[3], s[4], s[5], 0}, NULL, 16);
                c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
                s += 6;
            }
            o += put_utf8(o, c);
            break;
        }
        default: *o++ = *s++; break; /* \" \\ \/ */
        }
    }
    if (*s != '"') ps->err = 1;
    *o = 0;
    ps->p = *s ? s + 1 : s;
    return out;
}

static jv value(parser *ps) {
    jv v = {0};
    ws(ps);
    char c = *ps->p;
    if (c == '{' || c == '[') {
        v.type = c == '{' ? J_OBJ : J_ARR;
        char close = c == '{' ? '}' : ']';
        ps->p++;
        ws(ps);
        if (*ps->p == close) {
            ps->p++;
            return v;
        }
        while (!ps->err) {
            char *key = NULL;
            if (v.type == J_OBJ) {
                ws(ps);
                if (*ps->p != '"') break;
                key = string(ps);
                ws(ps);
                if (*ps->p++ != ':') break;
            }
            jv item = value(ps);
            push(&v, &item, key);
            ws(ps);
            if (*ps->p == ',') {
                ps->p++;
                continue;
            }
            if (*ps->p++ == close) return v;
            break;
        }
        ps->err = 1;
    } else if (c == '"') {
        v.type = J_STR;
        v.str = string(ps);
    } else if (!strncmp(ps->p, "true", 4) || !strncmp(ps->p, "false", 5)) {
        v.type = J_BOOL;
        v.num = c == 't';
        ps->p += c == 't' ? 4 : 5;
    } else if (!strncmp(ps->p, "null", 4)) {
        ps->p += 4;
    } else {
        char *end;
        v.type = J_NUM;
        v.num = strtod(ps->p, &end);
        if (end == ps->p) ps->err = 1;
        ps->p = end;
    }
    return v;
}

jv *json_parse(const char *text) {
    parser ps = {text, 0};
    jv *v = malloc(sizeof *v);
    *v = value(&ps);
    ws(&ps);
    if (ps.err || *ps.p) {
        free(v);
        return NULL;
    }
    return v;
}

const jv *json_get(const jv *obj, const char *key) {
    if (!obj || obj->type != J_OBJ) return NULL;
    for (size_t i = 0; i < obj->n; i++)
        if (!strcmp(obj->keys[i], key)) return &obj->items[i];
    return NULL;
}

static void release(jv *v) {
    for (size_t i = 0; i < v->n; i++) {
        release(&v->items[i]);
        if (v->keys) free(v->keys[i]);
    }
    free(v->items);
    free(v->keys);
    free(v->str);
}

void json_free(jv *v) {
    if (!v) return;
    release(v);
    free(v);
}
