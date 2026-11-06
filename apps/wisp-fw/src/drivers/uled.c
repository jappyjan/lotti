/*
 * SPDX-License-Identifier: MIT
 *
 * G2 microLED panel on MSPI0: JBD4010 or Hongshi A6N-G, 640x480 4 bpp. Neither panel has a
 * public datasheet. Every opcode, register value, order and delay below comes from static
 * analysis of stock 2.4.0.24 (docs/wisp/hardware.md "Display", with addresses and confidence);
 * the code is Wisp's own.
 *
 * Bus: commands, register access and reads are serial PIO (JBD 31.25 MHz, A6N-G 24 MHz); pixels
 * are quad 1-1-4 (instruction and address on one line, data on four): full frames by DMA, JBD row
 * updates by PIO, one row per transfer, as stock.
 *
 * Power (PM runtime): RESUME = rails + GPIOs in stock's order, init, blank frame, brightness,
 * offset; SUSPEND = stock's power-down order, rails off. Neither panel has a sleep command:
 * off means unpowered, which is also what stock does when the display is off.
 *
 * Frame: the driver owns the panel frame buffer (uled_frame()) in uncached SRAM so DMA reads it
 * directly; the HAL composes into it (src/display/wisp_flush.c) and asks for rows to be sent.
 */

#define DT_DRV_COMPAT even_g2_uled

#include "uled.h"

#include <string.h>

#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/mspi.h>
#include <zephyr/drivers/regulator.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/pm/device_runtime.h>

LOG_MODULE_REGISTER(uled, CONFIG_LOG_DEFAULT_LEVEL);

/* JBD4010 opcodes (meanings in comments are inferred, hardware.md). */
#define JBD_RESET_EN   0x66
#define JBD_RESET      0x99
#define JBD_WREN       0x06
#define JBD_WRSR       0x01
#define JBD_STATUS1    0x05
#define JBD_STATUS2    0x35
#define JBD_CHIP_ID    0x9F
#define JBD_OFFSET     0xC0
#define JBD_COMMIT     0x97
#define JBD_MODE_3     0x73
#define JBD_LUM        0x36
#define JBD_CURRENT    0x46
#define JBD_REG_31     0x31
#define JBD_OPEN       0xA9
#define JBD_CLOSE      0xA3
#define JBD_PIXELS     0x62
#define JBD_PIXELS_RD  0x63
#define JBD_STATUS1_FAULT 0x90

/* A6N-G: register frames {bank, reg, value}; reads with a 2-byte address {bank | 1, reg}. */
#define A6_BANK0_WR 0x78
#define A6_BANK1_WR 0x7A
#define A6_BANK0_RD 0x79
#define A6_BANK1_RD 0x7B
#define A6_FRAME_ADDR 0x32002C00u /* 0x32 quad write + DCS 0x2C memory write [I] */

struct uled_config {
	const struct device *bus;
	struct mspi_dev_id dev_id;
	struct mspi_dev_cfg serial;
	struct mspi_dev_cfg quad;
	enum uled_panel panel;
	const struct device *vdd;
	const struct device *vio;
	struct gpio_dt_spec en_a, en_b, en_c;
	uint8_t off_x, off_y;
	uint16_t max_lum;
};

struct uled_data {
	struct k_mutex lock;
	bool on;
	bool quad;
	uint8_t level;
	int16_t a6_coarse; /* cached E7, -1 = unread */
	uint8_t row[ULED_STRIDE + 2u] __aligned(4);
};

/* The panel frame (+2 trailing zero bytes), uncached for DMA. One panel per temple. */
static uint8_t uled_fb[ULED_FRAME_BYTES] __aligned(32) __attribute__((section("SRAM_NO_CACHE")));

uint8_t *uled_frame(const struct device *dev)
{
	ARG_UNUSED(dev);
	return uled_fb;
}

enum uled_panel uled_panel(const struct device *dev)
{
	return ((const struct uled_config *)dev->config)->panel;
}

/* ---- bus ------------------------------------------------------------------------------------ */

static int bus_mode(const struct device *dev, bool quad)
{
	const struct uled_config *cfg = dev->config;
	struct uled_data *data = dev->data;
	int err;

	if (data->quad == quad) {
		return 0;
	}
	err = mspi_dev_config(cfg->bus, &cfg->dev_id, MSPI_DEVICE_CONFIG_ALL,
			      quad ? &cfg->quad : &cfg->serial);
	if (err == 0) {
		data->quad = quad;
	}
	return err;
}

static int bus_xfer(const struct device *dev, bool quad, enum mspi_xfer_mode mode,
		    enum mspi_xfer_direction dir, uint8_t cmd_len, uint32_t cmd, uint8_t addr_len,
		    uint32_t addr, uint8_t rx_dummy, uint8_t *buf, uint32_t len)
{
	const struct uled_config *cfg = dev->config;
	struct mspi_xfer_packet pkt = {
		.dir = dir,
		.cmd = cmd,
		.address = addr,
		.data_buf = buf,
		.num_bytes = len,
	};
	struct mspi_xfer xfer = {
		.async = false,
		.xfer_mode = mode,
		.tx_dummy = 0,
		.rx_dummy = rx_dummy,
		.cmd_length = cmd_len,
		.addr_length = addr_len,
		.hold_ce = false,
		.priority = 1,
		.packets = &pkt,
		.num_packet = 1,
		.timeout = mode == MSPI_DMA ? 100 : 10,
	};
	int err = bus_mode(dev, quad);

	return err ? err : mspi_transceive(cfg->bus, &cfg->dev_id, &xfer);
}

/* JBD: instruction + payload, serial. */
static int jbd_cmd(const struct device *dev, uint8_t op, const uint8_t *payload, uint32_t len)
{
	struct uled_data *data = dev->data;
	uint8_t buf[4] = {0};

	__ASSERT_NO_MSG(len <= sizeof(buf));
	if (len) {
		memcpy(buf, payload, len);
	}
	return bus_xfer(dev, false, MSPI_PIO, MSPI_TX, 1, op, 0, 0, 0, len ? buf : data->row, len);
}

static int jbd_op(const struct device *dev, uint8_t op)
{
	return jbd_cmd(dev, op, NULL, 0);
}

static int jbd_op1(const struct device *dev, uint8_t op, uint8_t v)
{
	return jbd_cmd(dev, op, &v, 1);
}

static int jbd_read(const struct device *dev, uint8_t op, uint8_t *buf, uint32_t len)
{
	/* Instruction, one turnaround cycle, then data (stock serial cfg: TA 1). */
	return bus_xfer(dev, false, MSPI_PIO, MSPI_RX, 1, op, 0, 0, 1, buf, len);
}

/* A6N-G: raw 3-byte register write, no instruction, no address phase. */
static int a6_wr(const struct device *dev, uint8_t bank, uint8_t reg, uint8_t val)
{
	struct uled_data *data = dev->data;

	data->row[0] = bank ? A6_BANK1_WR : A6_BANK0_WR;
	data->row[1] = reg;
	data->row[2] = val;
	return bus_xfer(dev, false, MSPI_PIO, MSPI_TX, 0, 0, 0, 0, 0, data->row, 3);
}

static int a6_rd(const struct device *dev, uint8_t bank, uint8_t reg, uint8_t *val)
{
	int err = -EIO;

	/* Stock retries up to 3 times, 2 ms apart. */
	for (int i = 0; i < 3 && err; i++) {
		if (i) {
			k_msleep(2);
		}
		err = bus_xfer(dev, false, MSPI_PIO, MSPI_RX, 0, 0, 2,
			       (uint32_t)(bank ? A6_BANK1_RD : A6_BANK0_RD) << 8 | reg, 0, val, 1);
	}
	return err;
}

/* ---- frames --------------------------------------------------------------------------------- */

static int full_frame(const struct device *dev)
{
	const struct uled_config *cfg = dev->config;
	int err;

	uled_fb[ULED_FRAME_BYTES - 2] = 0;
	uled_fb[ULED_FRAME_BYTES - 1] = 0;
	if (cfg->panel == ULED_JBD4010) {
		/* WriteInstr 0x62 (quad cfg), address 0, 153 602 bytes, then commit. */
		err = bus_xfer(dev, true, MSPI_DMA, MSPI_TX, 1, JBD_PIXELS, 4, 0, 0, uled_fb,
			       ULED_FRAME_BYTES);
		err = err ? err : jbd_op(dev, JBD_COMMIT);
		k_msleep(2);
		return err;
	}
	/* A6N-G: no instruction, 4-byte address 0x32002C00, no commit. */
	return bus_xfer(dev, true, MSPI_DMA, MSPI_TX, 0, 0, 4, A6_FRAME_ADDR, 0, uled_fb,
			ULED_FRAME_BYTES);
}

static int jbd_rows(const struct device *dev, uint16_t y0, uint16_t rows)
{
	struct uled_data *data = dev->data;
	int err = 0;

	for (uint16_t y = y0; y < y0 + rows && !err; y++) {
		/* Address word ((row << 10) & 0x7FC00 | col) << 8 | 0xFF, col 0; span + 2 zero bytes. */
		uint32_t addr = ((((uint32_t)y << 10) & 0x7FC00u) << 8) | 0xFFu;

		memcpy(data->row, &uled_fb[(size_t)y * ULED_STRIDE], ULED_STRIDE);
		data->row[ULED_STRIDE] = 0;
		data->row[ULED_STRIDE + 1] = 0;
		err = bus_xfer(dev, true, MSPI_PIO, MSPI_TX, 1, JBD_PIXELS, 4, addr, 0, data->row,
			       sizeof(data->row));
	}
	err = err ? err : jbd_op(dev, JBD_COMMIT);
	k_msleep(1);
	return err;
}

int uled_write_rows(const struct device *dev, const uint8_t *frame, uint16_t y0, uint16_t rows)
{
	const struct uled_config *cfg = dev->config;
	struct uled_data *data = dev->data;
	int err;

	if (frame != uled_fb || rows == 0 || y0 + rows > ULED_HEIGHT) {
		return -EINVAL;
	}
	k_mutex_lock(&data->lock, K_FOREVER);
	if (!data->on) {
		err = -EBUSY;
	} else if (cfg->panel == ULED_A6NG || (y0 == 0 && rows == ULED_HEIGHT) || rows > 240) {
		/* A6N-G has no partial update; on JBD a long run is cheaper as one DMA. */
		err = full_frame(dev);
	} else {
		err = jbd_rows(dev, y0, rows);
	}
	k_mutex_unlock(&data->lock);
	return err;
}

/* ---- JBD4010 -------------------------------------------------------------------------------- */

static void jbd_level(const struct uled_config *cfg, uint8_t level, uint8_t *current,
		      uint32_t *lum)
{
	uint32_t m = cfg->max_lum;

	level = CLAMP(level, 2, 100);
	if (level < 31) {
		*current = 0;
		*lum = ((m - 333u) * (level - 2u) + 14u) / 28u + 333u;
	} else {
		*current = (uint8_t)((36u * level - 1045u) / 70u);
		*lum = m;
	}
}

static int jbd_lum_current(const struct device *dev, uint8_t level, bool open)
{
	const struct uled_config *cfg = dev->config;
	uint8_t current;
	uint32_t lum;
	int err = 0;

	jbd_level(cfg, level, &current, &lum);
	/* Stock's payload as it is on the wire: the word lum >> 8, two bytes, low first. */
	uint8_t lumb[2] = {(uint8_t)(lum >> 8), (uint8_t)(lum >> 16)};

	if (open) {
		err = jbd_op(dev, JBD_WREN);
		err = err ? err : jbd_op(dev, JBD_OPEN);
	}
	err = err ? err : jbd_cmd(dev, JBD_LUM, lumb, 2);
	err = err ? err : jbd_op1(dev, JBD_CURRENT, current & 0x3F);
	err = err ? err : jbd_op1(dev, JBD_REG_31, 0x04);
	err = err ? err : jbd_op(dev, JBD_CLOSE);
	err = err ? err : jbd_op(dev, JBD_COMMIT);
	k_msleep(1);
	return err;
}

static int jbd_offset(const struct device *dev)
{
	const struct uled_config *cfg = dev->config;
	uint8_t xy[2] = {CLAMP(cfg->off_x, 2, 22), CLAMP(cfg->off_y, 2, 18)};
	int err;

	err = jbd_op(dev, JBD_OPEN);
	err = err ? err : jbd_cmd(dev, JBD_OFFSET, xy, 2);
	err = err ? err : jbd_op(dev, JBD_CLOSE);
	err = err ? err : jbd_op(dev, JBD_COMMIT);
	k_msleep(1);
	return err;
}

static int jbd_init(const struct device *dev)
{
	struct uled_data *data = dev->data;
	static const uint8_t corners[5][2] = {{0, 0}, {0, 20}, {24, 0}, {24, 20}, {12, 10}};
	uint8_t id[4] = {0};
	int err;

	err = jbd_op(dev, JBD_RESET_EN);
	k_msleep(1);
	err = err ? err : jbd_op(dev, JBD_RESET);
	k_msleep(70);
	err = err ? err : jbd_op(dev, JBD_WREN);
	err = err ? err : jbd_op1(dev, JBD_WRSR, 0x10);
	if (!err) {
		memset(uled_fb, 0, sizeof(uled_fb));
		err = full_frame(dev);
	}
	/* Stock walks the window offset through the corners and the centre, each committed. */
	for (int i = 0; i < 5 && !err; i++) {
		err = jbd_cmd(dev, JBD_OFFSET, corners[i], 2);
		err = err ? err : jbd_op(dev, JBD_COMMIT);
		k_msleep(1);
	}
	for (int i = 0; i < 2 && !err; i++) {
		err = jbd_op(dev, JBD_MODE_3);
		k_busy_wait(100);
		err = err ? err : jbd_op(dev, JBD_COMMIT);
		k_msleep(1);
	}
	err = err ? err : jbd_lum_current(dev, data->level, false);
	err = err ? err : jbd_offset(dev);
	err = err ? err : jbd_read(dev, JBD_CHIP_ID, id, sizeof(id));
	if (!err) {
		LOG_INF("JBD4010 id %04x", id[1] << 8 | id[2]);
	}
	return err;
}

static int jbd_check(const struct device *dev)
{
	uint8_t sr1 = 0, sr2 = 0;
	int err = jbd_read(dev, JBD_STATUS1, &sr1, 1);

	err = err ? err : jbd_read(dev, JBD_STATUS2, &sr2, 1);
	if (err) {
		return err;
	}
	/* Stock: SR1 == 0x90 or SR2 == 0 is a fault. */
	return (sr1 == JBD_STATUS1_FAULT || sr2 == 0) ? -EIO : 0;
}

/* ---- A6N-G ---------------------------------------------------------------------------------- */

/* Stock's init stream {bank, reg, value, delay µs}. */
static const struct {
	uint8_t bank, reg, val;
	uint8_t us;
} a6_init_seq[] = {
	{0, 0xBE, 0x84, 6},   {1, 0x7E, 0x02, 6},   {1, 0xA5, 0x40, 6},   {0, 0xF1, 0x3F, 100},
	{0, 0xE2, 0xFF, 100}, {0, 0xF7, 0xFC, 100}, {0, 0x78, 0x0A, 100}, {0, 0x7C, 0x12, 100},
	{0, 0xB7, 0x80, 100}, {0, 0xB0, 0x80, 100},
};

static int lerp(const int16_t *t, int n, int x, int step)
{
	int i = x / step;

	if (i >= n - 1) {
		return t[n - 1];
	}
	return t[i] + (t[i + 1] - t[i]) * (x - i * step) / step;
}

static int a6_brightness(const struct device *dev, uint8_t level)
{
	struct uled_data *data = dev->data;
	static const int16_t decile[] = {-5, 1, 10, 13, 28, 41, 53, 69, 80, 94, 100};
	static const int16_t fine_hi[] = {36, 50, 67, 91, 116, 152, 255};
	int m = lerp(decile, ARRAY_SIZE(decile), CLAMP(level, 1, 100), 10);
	int fine, coarse;
	int err = 0;

	if (data->a6_coarse < 0) {
		uint8_t v = 0;

		err = a6_rd(dev, 0, 0xE7, &v);
		if (err) {
			return err;
		}
		data->a6_coarse = MIN(v, 15);
	}
	coarse = data->a6_coarse;
	if (level >= 40) {
		fine = lerp(fine_hi, ARRAY_SIZE(fine_hi), level - 40, 10);
	} else if (m < 26) {
		fine = m + 5;
		coarse = MAX(0, coarse - (25 - m) / 3);
	} else if (m >= 100) {
		fine = 255;
	} else {
		fine = (225 * m - 5588) / 75 + 30;
	}
	fine = CLAMP(fine, 0, 255);
	err = a6_wr(dev, 0, 0xE7, (uint8_t)coarse);
	k_busy_wait(100);
	err = err ? err : a6_wr(dev, 0, 0xE2, (uint8_t)fine);
	k_msleep(1);
	return err;
}

static int a6_offset_reg(const struct device *dev, uint8_t reg, uint8_t v)
{
	uint8_t cur = 0;
	int err = a6_rd(dev, 0, reg, &cur);

	k_busy_wait(100);
	err = err ? err : a6_wr(dev, 0, reg, (uint8_t)(MIN(v, 16) + (cur & 0xE0)));
	k_busy_wait(100);
	err = err ? err : a6_wr(dev, 0, 0xD9, 0xBF);
	k_busy_wait(100);
	err = err ? err : a6_wr(dev, 0, 0xD9, 0xFF);
	k_busy_wait(100);
	return err;
}

static int a6_init(const struct device *dev)
{
	const struct uled_config *cfg = dev->config;
	struct uled_data *data = dev->data;
	uint8_t v = 0;
	int err;

	err = a6_wr(dev, 1, 0x55, 0x00);
	for (size_t i = 0; i < ARRAY_SIZE(a6_init_seq) && !err; i++) {
		err = a6_wr(dev, a6_init_seq[i].bank, a6_init_seq[i].reg, a6_init_seq[i].val);
		k_busy_wait(a6_init_seq[i].us);
	}
	k_busy_wait(100);
	err = err ? err : a6_wr(dev, 0, 0xF0, 0x28);
	k_busy_wait(100);
	err = err ? err : a6_rd(dev, 0, 0x00, &v);
	if (!err && v != 0x36) {
		LOG_WRN("A6N-G reg 0x00 = 0x%02x, expected 0x36", v);
	}
	/* Chip ID: bank 0 register 0x06 reads 1 (stock checks it after configure). */
	err = err ? err : a6_rd(dev, 0, 0x06, &v);
	if (!err && v != 0x01) {
		LOG_ERR("A6N-G chip id reg 0x06 = 0x%02x", v);
		err = -ENODEV;
	}
	k_msleep(1);
	if (!err) {
		memset(uled_fb, 0, sizeof(uled_fb));
		err = full_frame(dev);
	}
	err = err ? err : a6_brightness(dev, data->level);
	k_msleep(2);
	err = err ? err : a6_offset_reg(dev, 0xEF, cfg->off_x);
	err = err ? err : a6_offset_reg(dev, 0xF0, cfg->off_y);
	/* enable(0): 50 ms, then GPIO142. */
	k_msleep(50);
	if (!err) {
		gpio_pin_set_dt(&cfg->en_a, 1);
	}
	return err;
}

static int a6_check(const struct device *dev)
{
	uint8_t asic = 0, panel = 0;
	int err = a6_rd(dev, 0, 0xBE, &asic);

	err = err ? err : a6_rd(dev, 0, 0x62, &panel);
	if (err) {
		return err;
	}
	return (asic == 0x84 && (panel == 0x77 || panel == 0x57)) ? 0 : -EIO;
}

/* ---- power ---------------------------------------------------------------------------------- */

static void set_opt(const struct gpio_dt_spec *g, int v)
{
	if (g->port) {
		gpio_pin_set_dt(g, v);
	}
}

/* Run one power-up step; log which one failed. */
#define STEP(expr)                                                                                 \
	do {                                                                                       \
		if (err == 0) {                                                                    \
			err = (expr);                                                              \
			if (err) {                                                                 \
				LOG_ERR("power-up: %s -> %d", #expr, err);                         \
			}                                                                          \
		}                                                                                  \
	} while (0)

static int power_up(const struct device *dev)
{
	const struct uled_config *cfg = dev->config;
	struct uled_data *data = dev->data;
	int err = 0;

	STEP(pm_device_runtime_get(cfg->bus));
	if (err) {
		return err;
	}
	data->quad = true; /* force a full serial configure */
	if (cfg->panel == ULED_JBD4010) {
		if (cfg->vio) {
			STEP(regulator_enable(cfg->vio));
			k_msleep(3);
		}
		STEP(regulator_enable(cfg->vdd));
		k_msleep(3);
		set_opt(&cfg->en_a, 1);
		k_msleep(10);
		STEP(bus_mode(dev, false));
		set_opt(&cfg->en_c, 1);
		STEP(jbd_init(dev));
	} else {
		STEP(regulator_enable(cfg->vdd));
		k_msleep(7);
		STEP(bus_mode(dev, false));
		k_msleep(1);
		set_opt(&cfg->en_b, 1);
		k_msleep(110);
		STEP(a6_init(dev));
	}
	return err;
}

static void power_down(const struct device *dev)
{
	const struct uled_config *cfg = dev->config;

	/* Stock order; every step runs even if an earlier one failed. */
	if (cfg->panel == ULED_JBD4010) {
		set_opt(&cfg->en_a, 0);
		k_msleep(3);
		(void)regulator_disable(cfg->vdd);
		k_msleep(3);
		if (cfg->vio) {
			(void)regulator_disable(cfg->vio);
		}
		k_msleep(10);
		set_opt(&cfg->en_c, 0);
	} else {
		set_opt(&cfg->en_a, 0);
		k_msleep(1);
		set_opt(&cfg->en_b, 0);
		k_msleep(1);
		(void)regulator_disable(cfg->vdd);
		k_msleep(10);
	}
	(void)pm_device_runtime_put(cfg->bus);
}

int uled_brightness(const struct device *dev, uint8_t level)
{
	const struct uled_config *cfg = dev->config;
	struct uled_data *data = dev->data;
	int err = 0;

	k_mutex_lock(&data->lock, K_FOREVER);
	data->level = CLAMP(level, 1, 100);
	if (data->on) {
		err = cfg->panel == ULED_JBD4010 ? jbd_lum_current(dev, data->level, true)
						 : a6_brightness(dev, data->level);
	}
	k_mutex_unlock(&data->lock);
	return err;
}

int uled_check(const struct device *dev)
{
	const struct uled_config *cfg = dev->config;
	struct uled_data *data = dev->data;
	int err;

	k_mutex_lock(&data->lock, K_FOREVER);
	err = !data->on ? -EBUSY : cfg->panel == ULED_JBD4010 ? jbd_check(dev) : a6_check(dev);
	k_mutex_unlock(&data->lock);
	return err;
}

static int uled_pm_action(const struct device *dev, enum pm_device_action action)
{
	struct uled_data *data = dev->data;
	int err = 0;

	k_mutex_lock(&data->lock, K_FOREVER);
	switch (action) {
	case PM_DEVICE_ACTION_RESUME:
		err = power_up(dev);
		if (err) {
			LOG_ERR("panel power-up failed (%d); powering down", err);
			power_down(dev);
		} else {
			data->on = true;
		}
		break;
	case PM_DEVICE_ACTION_SUSPEND:
		data->on = false;
		power_down(dev);
		break;
	default:
		err = -ENOTSUP;
		break;
	}
	k_mutex_unlock(&data->lock);
	return err;
}

static int uled_init(const struct device *dev)
{
	const struct uled_config *cfg = dev->config;
	struct uled_data *data = dev->data;
	const struct gpio_dt_spec *g[] = {&cfg->en_a, &cfg->en_b, &cfg->en_c};

	k_mutex_init(&data->lock);
	data->level = 50;
	data->a6_coarse = -1;
	if (!device_is_ready(cfg->bus) || !device_is_ready(cfg->vdd) ||
	    (cfg->vio && !device_is_ready(cfg->vio))) {
		return -ENODEV;
	}
	for (size_t i = 0; i < ARRAY_SIZE(g); i++) {
		if (g[i]->port && gpio_pin_configure_dt(g[i], GPIO_OUTPUT_INACTIVE)) {
			return -EIO;
		}
	}
	memset(uled_fb, 0, sizeof(uled_fb));
	return pm_device_driver_init(dev, uled_pm_action);
}

#define ULED_SERIAL_CFG(n)                                                                         \
	{                                                                                          \
		.ce_num = 0,                                                                       \
		.freq = DT_INST_ENUM_IDX(n, panel) == 0 ? 31250000 : 24000000,                     \
		.io_mode = MSPI_IO_MODE_SINGLE,                                                    \
		.data_rate = MSPI_DATA_RATE_SINGLE,                                                \
		.cpp = MSPI_CPP_MODE_0,                                                            \
		.endian = MSPI_XFER_LITTLE_ENDIAN,                                                 \
		.ce_polarity = MSPI_CE_ACTIVE_LOW,                                                 \
		.rx_dummy = DT_INST_ENUM_IDX(n, panel) == 0 ? 1 : 0,                               \
		.cmd_length = DT_INST_ENUM_IDX(n, panel) == 0 ? 1 : 0,                             \
		.addr_length = DT_INST_ENUM_IDX(n, panel) == 0 ? 3 : 2,                            \
	}

#define ULED_QUAD_CFG(n)                                                                           \
	{                                                                                          \
		.ce_num = 0,                                                                       \
		.freq = DT_INST_PROP(n, quad_frequency),                                           \
		.io_mode = MSPI_IO_MODE_QUAD_1_1_4,                                                \
		.data_rate = MSPI_DATA_RATE_SINGLE,                                                \
		.cpp = MSPI_CPP_MODE_0,                                                            \
		.endian = MSPI_XFER_LITTLE_ENDIAN,                                                 \
		.ce_polarity = MSPI_CE_ACTIVE_LOW,                                                 \
		.rx_dummy = DT_INST_ENUM_IDX(n, panel) == 0 ? 8 : 0,                               \
		.read_cmd = DT_INST_ENUM_IDX(n, panel) == 0 ? JBD_PIXELS_RD : 0,                   \
		.write_cmd = DT_INST_ENUM_IDX(n, panel) == 0 ? JBD_PIXELS : 0,                     \
		.cmd_length = DT_INST_ENUM_IDX(n, panel) == 0 ? 1 : 0,                             \
		.addr_length = 4,                                                                  \
	}

#define ULED_DEFINE(n)                                                                             \
	static struct uled_data uled_data_##n;                                                     \
	static const struct uled_config uled_config_##n = {                                        \
		.bus = DEVICE_DT_GET(DT_INST_BUS(n)),                                              \
		.dev_id = MSPI_DEVICE_ID_DT_INST(n),                                               \
		.serial = ULED_SERIAL_CFG(n),                                                      \
		.quad = ULED_QUAD_CFG(n),                                                          \
		.panel = DT_INST_ENUM_IDX(n, panel) == 0 ? ULED_JBD4010 : ULED_A6NG,               \
		.vdd = DEVICE_DT_GET(DT_INST_PHANDLE(n, vdd_supply)),                              \
		.vio = COND_CODE_1(DT_INST_NODE_HAS_PROP(n, vio_supply),                           \
				   (DEVICE_DT_GET(DT_INST_PHANDLE(n, vio_supply))), (NULL)),       \
		.en_a = GPIO_DT_SPEC_INST_GET(n, en_a_gpios),                                      \
		.en_b = GPIO_DT_SPEC_INST_GET_OR(n, en_b_gpios, {0}),                              \
		.en_c = GPIO_DT_SPEC_INST_GET_OR(n, en_c_gpios, {0}),                              \
		.off_x = DT_INST_PROP(n, offset_x),                                                \
		.off_y = DT_INST_PROP(n, offset_y),                                                \
		.max_lum = DT_INST_PROP(n, max_luminance),                                         \
	};                                                                                         \
	PM_DEVICE_DT_INST_DEFINE(n, uled_pm_action);                                               \
	DEVICE_DT_INST_DEFINE(n, uled_init, PM_DEVICE_DT_INST_GET(n), &uled_data_##n,              \
			      &uled_config_##n, POST_KERNEL, CONFIG_WISP_ULED_INIT_PRIORITY, NULL);

BUILD_ASSERT(DT_NUM_INST_STATUS_OKAY(DT_DRV_COMPAT) <= 1, "one panel per temple");

DT_INST_FOREACH_STATUS_OKAY(ULED_DEFINE)
