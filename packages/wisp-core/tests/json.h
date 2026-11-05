/* Minimal JSON reader for the vector tests (allocates; tests only). */
#ifndef WISP_TEST_JSON_H
#define WISP_TEST_JSON_H

#include <stddef.h>

typedef enum { J_NULL, J_BOOL, J_NUM, J_STR, J_ARR, J_OBJ } jtype;

typedef struct jv {
    jtype type;
    double num;        /* J_NUM, J_BOOL */
    char *str;         /* J_STR, NUL-terminated UTF-8 */
    size_t n;          /* J_ARR, J_OBJ: item count */
    struct jv *items;  /* J_ARR, J_OBJ */
    char **keys;       /* J_OBJ */
} jv;

/* NULL on a syntax error. */
jv *json_parse(const char *text);
const jv *json_get(const jv *obj, const char *key);
void json_free(jv *v);

#endif
