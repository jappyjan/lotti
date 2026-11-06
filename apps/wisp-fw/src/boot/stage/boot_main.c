/*
 * SPDX-License-Identifier: MIT
 *
 * Wisp Boot — the stage at 0x438000. See ../wisp_boot.h for the design and safety.md
 * "Fallback-to-stock". Flow on every boot:
 *
 *   arm + lock the watchdog -> NOR + littlefs mount (never formats) -> read wisp/boot.rec,
 *   the staging preamble and wisp/rescue.bin (header check + full CRC) -> decide -> write the
 *   record -> RUN_APP / RUN_APP_DEGRADED: jump to the app at 0x448000
 *             RESCUE: copy rescue.bin to the staging file, re-read and CRC it, write the
 *                     update flag, reset (the Even bootloader installs stock)
 *
 * Anything that fails before the decision (no NOR, no filesystem) runs the app degraded: the
 * app is the only remaining way in. A failed rescue (copy or verify) never writes the flag.
 */
#include <stddef.h>
#include <string.h>

#include "boot_hw.h"
#include "boot_nor.h"
#include "boot_services.h"
#include "lfs.h"
#include "wisp_boot.h"
#include "wisp_boot_layout.h"

/* ---- littlefs on the NOR, stock geometry ---------------------------------------------------- */

static int bd_read(const struct lfs_config *c, lfs_block_t b, lfs_off_t off, void *buf,
		   lfs_size_t n)
{
	return nor_read(WISP_LFS_BASE + b * c->block_size + off, buf, n) ? LFS_ERR_IO : 0;
}

static int bd_prog(const struct lfs_config *c, lfs_block_t b, lfs_off_t off, const void *buf,
		   lfs_size_t n)
{
	uint32_t a = WISP_LFS_BASE + b * c->block_size + off;
	const uint8_t *p = buf;

	while (n) { /* prog_size = 256 = one page, so this is one iteration per call */
		uint32_t c2 = 256u - (a & 255u);

		if (c2 > n) {
			c2 = n;
		}
		if (nor_prog(a, p, c2)) {
			return LFS_ERR_IO;
		}
		a += c2;
		p += c2;
		n -= c2;
	}
	return 0;
}

static int bd_erase(const struct lfs_config *c, lfs_block_t b)
{
	hw_wdt_feed();
	return nor_erase_4k(WISP_LFS_BASE + b * c->block_size) ? LFS_ERR_IO : 0;
}

static int bd_sync(const struct lfs_config *c)
{
	(void)c;
	return 0;
}

static uint8_t read_buf[WISP_LFS_CACHE_SIZE], prog_buf[WISP_LFS_CACHE_SIZE];
static uint8_t look_buf[WISP_LFS_LOOKAHEAD] __attribute__((aligned(8)));
static uint8_t fbuf_a[WISP_LFS_CACHE_SIZE], fbuf_b[WISP_LFS_CACHE_SIZE];
static uint8_t chunk[WISP_LFS_CACHE_SIZE];

static const struct lfs_config cfg = {
	.read = bd_read,
	.prog = bd_prog,
	.erase = bd_erase,
	.sync = bd_sync,
	.read_size = WISP_LFS_READ_SIZE,
	.prog_size = WISP_LFS_PROG_SIZE,
	.block_size = WISP_LFS_BLOCK_SIZE,
	.block_count = WISP_LFS_BLOCK_COUNT,
	.block_cycles = WISP_LFS_BLOCK_CYCLES,
	.cache_size = WISP_LFS_CACHE_SIZE,
	.lookahead_size = WISP_LFS_LOOKAHEAD,
	.read_buffer = read_buf,
	.prog_buffer = prog_buf,
	.lookahead_buffer = look_buf,
};

static lfs_t lfs;
static int mounted;

static int fs_up(void)
{
	if (mounted) {
		return 0;
	}
	if (nor_init() != 0 || lfs_mount(&lfs, &cfg) != 0) {
		return -1;
	}
	mounted = 1;
	return 0;
}

static int open_file(lfs_file_t *f, uint8_t *buf, const char *path, int flags)
{
	static struct lfs_file_config fc[2];
	struct lfs_file_config *c = &fc[buf == fbuf_a ? 0 : 1];

	memset(c, 0, sizeof(*c));
	c->buffer = buf;
	return lfs_file_opencfg(&lfs, f, path, flags, c);
}

/* ---- boot record ------------------------------------------------------------------------- */

static int record_read(struct wisp_boot_record *r)
{
	lfs_file_t f;
	lfs_ssize_t n;

	if (open_file(&f, fbuf_a, WISP_PATH_RECORD, LFS_O_RDONLY) < 0) {
		return -1;
	}
	n = lfs_file_read(&lfs, &f, r, sizeof(*r));
	lfs_file_close(&lfs, &f);
	return n == (lfs_ssize_t)sizeof(*r) ? 0 : -1;
}

static int record_write(const struct wisp_boot_record *r)
{
	lfs_file_t f;
	int e = lfs_mkdir(&lfs, WISP_PATH_DIR);

	if (e && e != LFS_ERR_EXIST) {
		return e;
	}
	if ((e = open_file(&f, fbuf_a, WISP_PATH_RECORD, LFS_O_WRONLY | LFS_O_CREAT | LFS_O_TRUNC)) <
	    0) {
		return e;
	}
	if (lfs_file_write(&lfs, &f, r, sizeof(*r)) != (lfs_ssize_t)sizeof(*r)) {
		lfs_file_close(&lfs, &f);
		return -1;
	}
	return lfs_file_close(&lfs, &f); /* commits atomically */
}

/* ---- images ------------------------------------------------------------------------------ */

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* Preamble CRC word of the staging file; returns 0 if it has no preamble. */
static int staging_id(uint32_t *id)
{
	lfs_file_t f;
	uint8_t pre[8];
	lfs_ssize_t n;

	if (open_file(&f, fbuf_a, WISP_PATH_STAGING, LFS_O_RDONLY) < 0) {
		return 0;
	}
	n = lfs_file_read(&lfs, &f, pre, sizeof(pre));
	lfs_file_close(&lfs, &f);
	if (n != (lfs_ssize_t)sizeof(pre)) {
		return 0;
	}
	*id = le32(pre + 4);
	return 1;
}

/* Full check of a staged-format main image: header (rule 3) + zlib CRC over [8:size). */
__attribute__((noinline)) static int image_verify(const char *path, uint8_t *buf, uint32_t *id)
{
	lfs_file_t f;
	uint8_t head[WISP_PREAMBLE_SIZE + 8];
	lfs_soff_t size;
	uint32_t crc, left;
	int ok = 0;

	if (open_file(&f, buf, path, LFS_O_RDONLY) < 0) {
		return 0;
	}
	size = lfs_file_size(&lfs, &f);
	if (size >= (lfs_soff_t)sizeof(head) &&
	    lfs_file_read(&lfs, &f, head, sizeof(head)) == (lfs_ssize_t)sizeof(head) &&
	    wisp_boot_image_check(head, le32(head + 32), le32(head + 36), (uint32_t)size) == 0) {
		crc = wisp_boot_crc32(0, head + 8, sizeof(head) - 8);
		left = (uint32_t)size - sizeof(head);
		ok = 1;
		while (left) {
			uint32_t c = left > sizeof(chunk) ? sizeof(chunk) : left;

			if (lfs_file_read(&lfs, &f, chunk, c) != (lfs_ssize_t)c) {
				ok = 0;
				break;
			}
			crc = wisp_boot_crc32(crc, chunk, c);
			left -= c;
			hw_wdt_feed();
		}
		if (ok && crc != le32(head + 4)) {
			ok = 0;
		}
		*id = le32(head + 4);
	}
	lfs_file_close(&lfs, &f);
	return ok;
}

__attribute__((noinline)) static int rescue_copy(void)
{
	lfs_file_t in, out;
	lfs_ssize_t n;
	int e;

	if (open_file(&in, fbuf_a, WISP_PATH_RESCUE, LFS_O_RDONLY) < 0) {
		return -1;
	}
	if ((e = open_file(&out, fbuf_b, WISP_PATH_STAGING,
			   LFS_O_WRONLY | LFS_O_CREAT | LFS_O_TRUNC)) < 0) {
		lfs_file_close(&lfs, &in);
		return e;
	}
	while ((n = lfs_file_read(&lfs, &in, chunk, sizeof(chunk))) > 0) {
		if (lfs_file_write(&lfs, &out, chunk, (lfs_size_t)n) != n) {
			n = -1;
			break;
		}
		hw_wdt_feed();
	}
	lfs_file_close(&lfs, &in);
	e = lfs_file_close(&lfs, &out); /* the new staging file becomes visible only here */
	return n < 0 ? -2 : e;
}

/* ---- services for the app ---------------------------------------------------------------- */

static int svc_confirm(void)
{
	struct wisp_boot_record r;

	/* The app may have reconfigured MSPI1 and written the filesystem since boot: bring the
	 * NOR up again and mount fresh instead of trusting state from boot time. */
	mounted = 0;
	if (fs_up() != 0 || record_read(&r) != 0 || !wisp_boot_record_valid(&r)) {
		return -1;
	}
	wisp_boot_confirm(&r);
	return record_write(&r);
}

__attribute__((section(".services"), used)) const struct wisp_boot_services wisp_boot_services = {
	.magic = WISP_BOOT_SERVICES_MAGIC,
	.version = 1,
	.confirm = svc_confirm,
};

/* ---- main --------------------------------------------------------------------------------- */

static const char *const action_names[] = {"run-app", "rescue", "run-app-degraded"};

/* The app's vector table must look runnable: SP in SRAM, outside Wisp Boot's RAM and 8-byte
 * aligned; reset handler Thumb and inside the app slot. An erased or garbage slot would fault
 * with the app's own (equally broken) fault vectors, i.e. lock the core up until the watchdog
 * fires; resetting at once counts the attempt just the same. */
static int app_vectors_ok(void)
{
	const volatile uint32_t *v = (const volatile uint32_t *)WISP_MAIN_BASE;
	uint32_t sp = v[0], pc = v[1];

	return sp > 0x20000000u && sp <= WISP_BOOT_RAM_BASE && !(sp & 7u) && (pc & 1u) &&
	       (pc & ~1u) >= WISP_MAIN_BASE + 8u && (pc & ~1u) < WISP_APP_CEILING;
}

_Noreturn static void run_app(void)
{
	if (!app_vectors_ok()) {
		hw_log("wisp-boot: no runnable app at 0x448000 -> reset\n");
		hw_reset();
	}
	hw_jump(WISP_MAIN_BASE);
}

_Noreturn void wisp_boot_main(void)
{
	struct wisp_boot_record stored, *sp = NULL;
	struct wisp_boot_inputs in = {0};
	struct wisp_boot_decision d;
	uint32_t id = 0;

	hw_wdt_arm();
	hw_log("\nwisp-boot: start\n");

	if (fs_up() != 0) {
		hw_log("wisp-boot: no filesystem -> run-app-degraded\n");
		run_app();
	}
	if (record_read(&stored) == 0) {
		sp = &stored;
	}
	in.staging_present = staging_id(&in.staging_id);
	in.rescue_ok = image_verify(WISP_PATH_RESCUE, fbuf_b, &in.rescue_id);
	in.rescue_hold = 0; /* TODO(rung 4): PSoC touch hold over I2C5 0x0C */

	d = wisp_boot_decide(sp, &in);
	hw_log_hex("wisp-boot: rescue.bin ok ", (uint32_t)in.rescue_ok);
	hw_log_hex("wisp-boot: reason ", (uint32_t)d.reason);
	hw_log_hex("wisp-boot: attempts ", d.record.attempts);
	hw_log_hex("wisp-boot: rescue tries ", d.record.rescue_tries);
	hw_log("wisp-boot: action ");
	hw_log(action_names[d.action]);
	hw_log("\n");

	if (record_write(&d.record) != 0) {
		/* The attempt was not counted. Rescue anyway if it was decided; else the app runs
		 * and the watchdog bounds what it can do. */
		hw_log("wisp-boot: record write failed\n");
	}

	if (d.action != WISP_BOOT_RESCUE) {
		run_app();
	}

	hw_log("wisp-boot: staging rescue.bin\n");
	if (rescue_copy() != 0) {
		hw_log("wisp-boot: copy failed, flag NOT written -> reset\n");
		hw_reset();
	}
	if (!image_verify(WISP_PATH_STAGING, fbuf_a, &id) || id != in.rescue_id) {
		hw_log("wisp-boot: staged copy does not verify, flag NOT written -> reset\n");
		hw_reset();
	}
	hw_log("wisp-boot: staged copy verified, writing update flag\n");
	if (hw_flag_set_install() != 0) {
		hw_log("wisp-boot: flag write failed -> reset\n");
		hw_reset();
	}
	hw_log("wisp-boot: flag set, reset into the Even bootloader\n");
	hw_reset();
}
