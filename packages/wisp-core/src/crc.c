/* Wisp core: checksums, nibble-table implementations (192 bytes of tables).
 * MIT License, Wisp contributors. */
#include "wisp/crc.h"

static const uint16_t crc16_tab[16] = {
    0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50a5, 0x60c6, 0x70e7,
    0x8108, 0x9129, 0xa14a, 0xb16b, 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef,
};

static const uint32_t crc32c_msb_tab[16] = {
    0x00000000, 0x1edc6f41, 0x3db8de82, 0x2364b1c3, 0x7b71bd04, 0x65add245, 0x46c96386, 0x58150cc7,
    0xf6e37a08, 0xe83f1549, 0xcb5ba48a, 0xd587cbcb, 0x8d92c70c, 0x934ea84d, 0xb02a198e, 0xaef676cf,
};

static const uint32_t crc32_tab[16] = {
    0x00000000, 0x1db71064, 0x3b6e20c8, 0x26d930ac, 0x76dc4190, 0x6b6b51f4, 0x4db26158, 0x5005713c,
    0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c, 0x9b64c2b0, 0x86d3d2d4, 0xa00ae278, 0xbdbdf21c,
};

uint16_t wisp_crc16(uint16_t crc, const void *data, size_t len) {
    const uint8_t *p = data;
    while (len--) {
        crc = (uint16_t)(crc << 4) ^ crc16_tab[(crc >> 12) ^ (*p >> 4)];
        crc = (uint16_t)(crc << 4) ^ crc16_tab[(crc >> 12) ^ (*p++ & 0xf)];
    }
    return crc;
}

uint32_t wisp_crc32c_msb(uint32_t crc, const void *data, size_t len) {
    const uint8_t *p = data;
    while (len--) {
        crc = (crc << 4) ^ crc32c_msb_tab[(crc >> 28) ^ (*p >> 4)];
        crc = (crc << 4) ^ crc32c_msb_tab[(crc >> 28) ^ (*p++ & 0xf)];
    }
    return crc;
}

uint32_t wisp_crc32(uint32_t crc, const void *data, size_t len) {
    const uint8_t *p = data;
    crc = ~crc;
    while (len--) {
        crc = (crc >> 4) ^ crc32_tab[(crc ^ *p) & 0xf];
        crc = (crc >> 4) ^ crc32_tab[(crc ^ (*p++ >> 4)) & 0xf];
    }
    return ~crc;
}
