/* Wisp core: checksums. MIT License, Wisp contributors.
 *
 * All three are incremental: pass the previous result to continue. */
#ifndef WISP_CRC_H
#define WISP_CRC_H

#include "common.h"

/* CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no xorout): frames. */
#define WISP_CRC16_INIT 0xFFFFu
uint16_t wisp_crc16(uint16_t crc, const void *data, size_t len);

/* CRC-32C polynomial 0x1EDC6F41, MSB-first, init 0, no xorout: EVENOTA bundles. */
#define WISP_CRC32C_MSB_INIT 0u
uint32_t wisp_crc32c_msb(uint32_t crc, const void *data, size_t len);

/* zlib crc32() (reflected 0xEDB88320, init/xorout 0xFFFFFFFF handled inside); start with 0. */
uint32_t wisp_crc32(uint32_t crc, const void *data, size_t len);

#endif
