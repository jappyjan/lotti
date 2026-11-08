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
 *
 * Every boot also lists /firmware (names, sizes, CRCs) and leaves what it saw in a status block in
 * its own RAM (wisp_boot_status.h), which the services table points at.
 *
 * Diagnostics (rung4.md, "W24 result and analysis", D1/D2), first thing on every boot, before the
 * NOR: the previous boot's record (wisp_diag.h) is kept in the status block and a fresh one is
 * started with RSTGEN.STAT; the nPM1300 watchdog is kicked once (boot_pmic.c, the only PMIC write
 * Wisp Boot makes: 07 04 01), so an Apollo reboot loop keeps re-kicking it and the PMIC never
 * power-cycles back to its reset values; then a short window on the case UART answers the boot
 * report (case-uart.md op 0x04): about 300 ms with no request, 100 ms after the last answered
 * one, never more than 1 s. Breadcrumbs mark every stage up to the hand-off.
 *
 * Observe-only build (WISP_BOOT_OBSERVE=1, rung4.md native-0): the same code with every write
 * compiled out. littlefs is built LFS_READONLY, the NOR driver has no program or erase, there is
 * no flag write, the record is read but never written, and the action is always run-app. The
 * decision is still computed and published as `would_action`, so the first native boot shows
 * what the fallback build would have done.
 */
#include <stddef.h>
#include <string.h>

#include "boot_hw.h"
#include "boot_nor.h"
#include "boot_pmic.h"
#include "boot_services.h"
#include "boot_uart.h"
#include "lfs.h"
#include "wisp_boot.h"
#include "wisp_boot_layout.h"
#include "wisp_boot_status.h"
#include "wisp_case_proto.h"
#include "wisp_diag.h"

/* ---- status block ------------------------------------------------------------------------ */

static struct wisp_boot_status st;

static void status_seal(void)
{
	st.crc = wisp_boot_crc32(0, &st, (uint32_t)__builtin_offsetof(struct wisp_boot_status, crc));
}

/* ---- littlefs on the NOR, stock geometry ---------------------------------------------------- */

static int bd_read(const struct lfs_config *c, lfs_block_t b, lfs_off_t off, void *buf,
		   lfs_size_t n)
{
	return nor_read(WISP_LFS_BASE + b * c->block_size + off, buf, n) ? LFS_ERR_IO : 0;
}

#if !WISP_BOOT_OBSERVE
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
#endif /* !WISP_BOOT_OBSERVE */

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
#if !WISP_BOOT_OBSERVE
	.prog = bd_prog,
	.erase = bd_erase,
#endif
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
	uint32_t id = 0;

	if (mounted) {
		return 0;
	}
	wisp_diag_mark(WISP_DIAG_BOOT_NOR);
	st.nor_result = nor_init(&id);
	st.nor_id = id;
	if (st.nor_result != 0) {
		return -1;
	}
	st.stage = WISP_BOOT_STAGE_NOR;
	st.mount_result = lfs_mount(&lfs, &cfg);
	if (st.mount_result != 0) {
		return -1;
	}
	st.stage = WISP_BOOT_STAGE_MOUNTED;
	wisp_diag_mark(WISP_DIAG_BOOT_MOUNTED);
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
	int e = open_file(&f, fbuf_a, WISP_PATH_RECORD, LFS_O_RDONLY);

	if (e < 0) {
		return e;
	}
	n = lfs_file_read(&lfs, &f, r, sizeof(*r));
	lfs_file_close(&lfs, &f);
	return n == (lfs_ssize_t)sizeof(*r) ? 0 : -1;
}

#if !WISP_BOOT_OBSERVE
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
#endif /* !WISP_BOOT_OBSERVE */

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
	st.staging_size = (uint32_t)lfs_file_size(&lfs, &f);
	n = lfs_file_read(&lfs, &f, pre, sizeof(pre));
	lfs_file_close(&lfs, &f);
	if (n != (lfs_ssize_t)sizeof(pre)) {
		return 0;
	}
	*id = le32(pre + 4);
	return 1;
}

/* Full check of a staged-format main image: header (rule 3) + zlib CRC over [8:size). */
__attribute__((noinline)) static int image_verify(const char *path, uint8_t *buf, uint32_t *id,
						  uint32_t *file_size)
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
	*file_size = size > 0 ? (uint32_t)size : 0;
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

/* ---- /firmware inventory (read-only) ----------------------------------------------------- */

static void inventory(void)
{
	static char path[sizeof(WISP_PATH_FIRMWARE) + 1 + LFS_NAME_MAX + 1];
	struct lfs_info info;
	lfs_dir_t dir;
	int e = lfs_dir_open(&lfs, &dir, WISP_PATH_FIRMWARE);

	st.inv_result = e;
	if (e < 0) {
		return;
	}
	while (lfs_dir_read(&lfs, &dir, &info) > 0) {
		struct wisp_boot_inv_entry *ent;
		size_t len = strlen(info.name);
		lfs_file_t f;

		if (info.type != LFS_TYPE_REG) {
			continue;
		}
		if (st.inv_count >= WISP_BOOT_INV_MAX) {
			st.inv_truncated = 1;
			break;
		}
		ent = &st.inv[st.inv_count++];
		memcpy(ent->name, info.name, len < WISP_BOOT_INV_NAME ? len : WISP_BOOT_INV_NAME);
		ent->size = info.size;
		memcpy(path, WISP_PATH_FIRMWARE "/", sizeof(WISP_PATH_FIRMWARE));
		memcpy(path + sizeof(WISP_PATH_FIRMWARE), info.name, len + 1);
		e = open_file(&f, fbuf_a, path, LFS_O_RDONLY);
		if (e < 0) {
			ent->result = e;
			continue;
		}
		for (;;) {
			lfs_ssize_t n = lfs_file_read(&lfs, &f, chunk, sizeof(chunk));

			if (n < 0) {
				ent->result = (int32_t)n;
				break;
			}
			if (n == 0) {
				break;
			}
			ent->crc = wisp_boot_crc32(ent->crc, chunk, (uint32_t)n);
			hw_wdt_feed();
		}
		lfs_file_close(&lfs, &f);
		if (ent->result == 0 && len >= WISP_BOOT_INV_NAME) {
			ent->result = 1; /* name cut */
		}
	}
	lfs_dir_close(&lfs, &dir);
}

#if !WISP_BOOT_OBSERVE
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
#endif /* !WISP_BOOT_OBSERVE */

/* ---- services for the app ---------------------------------------------------------------- */

static int svc_confirm(void)
{
#if WISP_BOOT_OBSERVE
	st.confirm_calls++;
	st.confirm_result = 0;
	status_seal();
	return 0;
#else
	struct wisp_boot_record r;
	int e;

	/* The app may have reconfigured MSPI1 and written the filesystem since boot: bring the
	 * NOR up again and mount fresh instead of trusting state from boot time. */
	mounted = 0;
	if (fs_up() != 0 || record_read(&r) != 0 || !wisp_boot_record_valid(&r)) {
		e = -1;
	} else {
		wisp_boot_confirm(&r);
		e = record_write(&r);
	}
	st.confirm_calls++;
	st.confirm_result = e;
	status_seal();
	return e;
#endif
}

__attribute__((section(".services"), used)) const struct wisp_boot_services wisp_boot_services = {
	.magic = WISP_BOOT_SERVICES_MAGIC,
	.version = WISP_BOOT_SERVICES_VERSION,
	.confirm = svc_confirm,
	.status = &st,
};

/* ---- diagnostics (wisp_diag.h) ------------------------------------------------------------ */

/* Keep the previous boot's record, start this boot's. */
static void diag_begin(void)
{
	volatile struct wisp_diag_record *r = wisp_diag();
	volatile uint32_t *w = (volatile uint32_t *)r;
	uint32_t boots = 1;

	st.rstgen_stat = REG(WISP_RSTGEN_STAT_ADDR);
	st.stimer_clksel = (uint8_t)(REG(WISP_STIMER_STCFG) & 0xFu);
	if (wisp_diag_valid(r)) {
		st.prev_valid = 1;
		memcpy(&st.prev, (const void *)r, sizeof(st.prev));
		boots = r->boots + 1u;
	}
	for (uint32_t i = 0; i < sizeof(*r) / 4u; i++) {
		w[i] = 0;
	}
	r->magic = WISP_DIAG_MAGIC;
	r->version = WISP_DIAG_VERSION;
	r->size = sizeof(*r);
	r->boots = boots;
	r->rstgen_stat = st.rstgen_stat;
	r->stimer_start = wisp_stimer_now();
	wisp_diag_mark(WISP_DIAG_BOOT_START);
}

static int report(void *ctx, uint8_t *out)
{
	(void)ctx;
	wisp_boot_report_fill(out, WISP_REPORT_SRC_BOOT, &st);
	st.window_answers++;
	return 0;
}

/* STIMER ticks at 32768 Hz (CLKSEL 3, the crystal the bootloader starts), or, without the crystal,
 * a count of poll-loop iterations / 32 (rough: a poll is about 1 us at the hand-off clock [I]). */
#define WINDOW_IDLE  (32768u * 3u / 10u) /* 300 ms with no request */
#define WINDOW_AFTER (32768u / 10u)      /* 100 ms after an answer */
#define WINDOW_MAX   32768u              /* 1 s in all */
#define WINDOW_GAP   (32768u / 50u)      /* 20 ms gap drops a partial request */
#define WINDOW_POLLS 2000000u            /* hard cap on polls, whatever the clock says */

/* The crystal is used only if STCFG selects it and the counter moves (a frozen STIMER would
 * otherwise hold the window open for ever, with the watchdog fed). */
static int stimer_counts(void)
{
	uint32_t t0 = wisp_stimer_now();

	for (uint32_t i = 0; i < 200000u; i++) {
		if (wisp_stimer_now() != t0) {
			return 1;
		}
	}
	return 0;
}

/* The boot-report window on the case UART: only BOOTREP is answered (wisp_case_proto.c with no
 * status callback); everything else is ignored, so the loader's and the app's protocols see
 * nothing from Wisp Boot. The watchdog is fed while it is open. */
static void report_window(void)
{
	static struct wisp_case_rx rx;
	static uint8_t out[WISP_CASE_MAX_FRAME];
	static const struct wisp_case_ops ops = {.boot_report = report};
	static const struct wisp_case_version ver;
	const int xt = st.stimer_clksel == 3u && stimer_counts();
	uint32_t start, now, until, last = 0;

	st.uart_result = (uint8_t)(boot_uart_init() != 0);
	if (st.uart_result) {
		return;
	}
	wisp_diag_mark(WISP_DIAG_BOOT_WINDOW);
	wisp_case_rx_init(&rx);
	start = xt ? wisp_stimer_now() : 0;
	until = WINDOW_IDLE;
	for (uint32_t i = 0;; i++) {
		int ch;

		now = (xt ? wisp_stimer_now() : i >> 5) - start; /* no crystal: ~32 polls a tick [I] */
		if (now >= until || now >= WINDOW_MAX || i >= WINDOW_POLLS) {
			break;
		}
		hw_wdt_feed();
		ch = boot_uart_getc();
		if (ch == -2) {
			wisp_case_rx_init(&rx);
		} else if (ch >= 0) {
			bool reset = false;
			size_t n;

			if (rx.len && now - last > WINDOW_GAP) {
				wisp_case_rx_init(&rx);
			}
			last = now;
			n = wisp_case_rx_byte(&rx, (uint8_t)ch, &ver, &ops, out, &reset);
			if (n) {
				boot_uart_write(out, (uint32_t)n);
				until = now + WINDOW_AFTER;
			}
		}
	}
	boot_uart_flush();
	st.window_ms = xt ? (uint16_t)((now * 125u) >> 12) : 0;
	wisp_diag_mark(WISP_DIAG_BOOT_WINDOW_END);
}

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

_Noreturn static void run_app(enum wisp_boot_action action)
{
	st.action = (uint8_t)action;
	if (st.stage < WISP_BOOT_STAGE_DECIDED) {
		st.would_action = (uint8_t)action;
	}
	st.stage = WISP_BOOT_STAGE_APP;
	status_seal();
	if (!app_vectors_ok()) {
		hw_log("wisp-boot: no runnable app at 0x448000 -> reset\n");
		wisp_diag_mark(WISP_DIAG_BOOT_RESET);
		hw_reset();
	}
	wisp_diag_mark(WISP_DIAG_BOOT_HANDOFF);
	hw_jump(WISP_MAIN_BASE);
}

_Noreturn void wisp_boot_main(void)
{
	struct wisp_boot_record stored, *sp = NULL;
	struct wisp_boot_inputs in = {0};
	struct wisp_boot_decision d;
	uint32_t id = 0;

	hw_wdt_arm();
	diag_begin();
	st.pmic_kick = boot_pmic_kick();
	wisp_diag_mark(WISP_DIAG_BOOT_PMIC);
	hw_wdt_feed();
	report_window();
	st.magic = WISP_BOOT_STATUS_MAGIC;
	st.version = WISP_BOOT_STATUS_VERSION;
	st.size = sizeof(st);
	st.build = (WISP_BOOT_OBSERVE ? WISP_BOOT_BUILD_OBSERVE : 0) |
		   (WISP_BOOT_LOG ? WISP_BOOT_BUILD_LOG : 0);
	st.mount_result = 1; /* not attempted */
	st.record_result = 1;
	st.inv_result = 1;
	st.stage = WISP_BOOT_STAGE_START;
	status_seal();
	hw_log(WISP_BOOT_OBSERVE ? "\nwisp-boot: start (observe-only)\n" : "\nwisp-boot: start\n");

	if (fs_up() != 0) {
		hw_log_hex("wisp-boot: NOR id ", st.nor_id);
		hw_log("wisp-boot: no filesystem -> run-app-degraded\n");
		run_app(WISP_BOOT_RUN_APP_DEGRADED);
	}
	st.record_result = record_read(&stored);
	if (st.record_result == 0) {
		sp = &stored;
		memcpy(st.record, &stored, sizeof(st.record));
	}
	in.staging_present = staging_id(&in.staging_id);
	in.rescue_ok = image_verify(WISP_PATH_RESCUE, fbuf_b, &in.rescue_id, &st.rescue_size);
	in.rescue_hold = 0; /* TODO(rung 4): PSoC touch hold over I2C5 0x0C */
	st.staging_present = in.staging_present;
	st.staging_id = in.staging_present ? in.staging_id : 0;
	st.rescue_ok = in.rescue_ok;
	st.rescue_id = in.rescue_id;
	inventory();
	st.stage = WISP_BOOT_STAGE_INPUTS;
	wisp_diag_mark(WISP_DIAG_BOOT_INPUTS);

	d = wisp_boot_decide(sp, &in);
	st.would_action = (uint8_t)d.action;
	st.reason = (uint8_t)d.reason;
	st.stage = WISP_BOOT_STAGE_DECIDED;
	wisp_diag_mark(WISP_DIAG_BOOT_DECIDED);
	status_seal();
	hw_log_hex("wisp-boot: rescue.bin ok ", (uint32_t)in.rescue_ok);
	hw_log_hex("wisp-boot: firmware files ", st.inv_count);
	hw_log_hex("wisp-boot: reason ", (uint32_t)d.reason);
	hw_log_hex("wisp-boot: attempts ", d.record.attempts);
	hw_log_hex("wisp-boot: rescue tries ", d.record.rescue_tries);
	hw_log("wisp-boot: action ");
	hw_log(action_names[d.action]);
	hw_log("\n");

#if WISP_BOOT_OBSERVE
	/* Observe-only: nothing is written, and the app always runs. */
	(void)id;
	hw_log("wisp-boot: observe-only -> run-app\n");
	run_app(WISP_BOOT_RUN_APP);
#else
	if (record_write(&d.record) != 0) {
		/* The attempt was not counted. Rescue anyway if it was decided; else the app runs
		 * and the watchdog bounds what it can do. */
		hw_log("wisp-boot: record write failed\n");
	}

	if (d.action != WISP_BOOT_RESCUE) {
		run_app(d.action);
	}

	hw_log("wisp-boot: staging rescue.bin\n");
	if (rescue_copy() != 0) {
		hw_log("wisp-boot: copy failed, flag NOT written -> reset\n");
		wisp_diag_mark(WISP_DIAG_BOOT_RESET);
		hw_reset();
	}
	if (!image_verify(WISP_PATH_STAGING, fbuf_a, &id, &st.staging_size) || id != in.rescue_id) {
		hw_log("wisp-boot: staged copy does not verify, flag NOT written -> reset\n");
		wisp_diag_mark(WISP_DIAG_BOOT_RESET);
		hw_reset();
	}
	hw_log("wisp-boot: staged copy verified, writing update flag\n");
	if (hw_flag_set_install() != 0) {
		hw_log("wisp-boot: flag write failed -> reset\n");
		wisp_diag_mark(WISP_DIAG_BOOT_RESET);
		hw_reset();
	}
	hw_log("wisp-boot: flag set, reset into the Even bootloader\n");
	wisp_diag_mark(WISP_DIAG_BOOT_RESET);
	hw_reset();
#endif
}
