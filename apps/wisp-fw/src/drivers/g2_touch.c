/*
 * SPDX-License-Identifier: MIT
 *
 * G2 touchpad + wear controller: Infineon PSoC 4000T at I2C5 0x0C running Even's firmware.
 * Protocol facts from the stock 2.4.0.24 main image (static analysis, docs/wisp/hardware.md
 * "Touch and wear"); no Even code.
 *
 * What the driver does:
 *   init    reset pulse (GPIO10 low 10 ms, release, settle 100 ms), command 1 (version, logged),
 *           command 8 (long-press threshold, logged), then arm the attention interrupt.
 *   attn    GPIO27 falling edge -> work item -> command 3 + 16-byte report read -> callback.
 *           Error flag 0x80 -> reset pulse + command 1, as stock; no event.
 *   suspend attention interrupt off, nothing else (the PSoC runs its own low-power scan; it has
 *           no host-controlled sleep in its command set).
 *
 * What it never does (safety rule 8): send command 2 (enter DFU), command 7 (writes the PSoC's
 * EEPROM), or any command byte outside the allow-list. Stock reprograms the PSoC when the
 * version read fails or differs from /firmware/touch.bin; Wisp has no such path at all.
 */

#define DT_DRV_COMPAT even_g2_touch

#include "g2_touch.h"

#include <string.h>

#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/byteorder.h>

LOG_MODULE_REGISTER(g2_touch, CONFIG_LOG_DEFAULT_LEVEL);

#define CMD_VERSION        1
#define CMD_REPORT         3
#define CMD_DIFFS          4
#define CMD_SAVE_BASELINE  5
#define CMD_READ_BASELINE  6
#define CMD_READ_LONGPRESS 8

struct g2_touch_config {
	struct i2c_dt_spec i2c;
	struct gpio_dt_spec attn;
	struct gpio_dt_spec reset;
	uint16_t settle_ms;
};

struct g2_touch_data {
	const struct device *dev;
	struct gpio_callback attn_cb;
	struct k_work work;
	struct k_mutex lock;
	g2_touch_cb cb;
	void *ctx;
	uint32_t version;
	uint8_t wear;
	bool suspended;
};

bool g2_touch_cmd_allowed(uint8_t cmd)
{
	switch (cmd) {
	case CMD_VERSION:
	case CMD_REPORT:
	case CMD_DIFFS:
	case CMD_SAVE_BASELINE:
	case CMD_READ_BASELINE:
	case CMD_READ_LONGPRESS:
		return true;
	default:
		return false; /* 2 = DFU, 7 = EEPROM write, everything unknown */
	}
}

/* One command: write [cmd], then (rx_len > 0) a separate read, stop + start in between, as
 * stock does (its HAL never uses a repeated start). */
static int psoc_cmd(const struct device *dev, uint8_t cmd, uint8_t *rx, size_t rx_len)
{
	const struct g2_touch_config *cfg = dev->config;
	int err;

	if (!g2_touch_cmd_allowed(cmd)) {
		LOG_ERR("refused PSoC command %u", cmd);
		return -EPERM;
	}
	err = i2c_write_dt(&cfg->i2c, &cmd, 1);
	if (err == 0 && rx_len) {
		err = i2c_read_dt(&cfg->i2c, rx, rx_len);
	}
	return err;
}

static void psoc_reset(const struct device *dev)
{
	const struct g2_touch_config *cfg = dev->config;

	gpio_pin_set_dt(&cfg->reset, 1); /* asserted = line low */
	k_msleep(10);
	gpio_pin_set_dt(&cfg->reset, 0);
	k_msleep(cfg->settle_ms);
}

static int read_version(const struct device *dev)
{
	struct g2_touch_data *data = dev->data;
	uint8_t v[4];
	int err = psoc_cmd(dev, CMD_VERSION, v, sizeof(v));

	/* A failed read is logged and nothing else (stock would reflash the PSoC here). */
	data->version = err ? 0 : sys_get_be32(v);
	return err;
}

static void decode(const uint8_t r[16], struct g2_touch_event *ev)
{
	memset(ev, 0, sizeof(*ev));
	ev->wear = r[0] <= G2_WEAR_ON ? r[0] : G2_WEAR_NO_CHANGE;
	ev->flags = r[1];
	ev->count = r[2];
	ev->speed = r[3];
	memcpy(ev->raw, r, 16);
}

int g2_touch_service(const struct device *dev)
{
	struct g2_touch_data *data = dev->data;
	struct g2_touch_event ev;
	uint8_t r[16];
	int err;

	k_mutex_lock(&data->lock, K_FOREVER);
	if (data->suspended) {
		k_mutex_unlock(&data->lock);
		return -EBUSY;
	}
	err = psoc_cmd(dev, CMD_REPORT, r, sizeof(r));
	if (err) {
		k_mutex_unlock(&data->lock);
		LOG_WRN("report read failed (%d)", err);
		return err;
	}
	decode(r, &ev);
	if (ev.flags & G2_TOUCH_ERROR) {
		LOG_WRN("PSoC reports an error; resetting it");
		psoc_reset(dev);
		(void)read_version(dev);
		k_mutex_unlock(&data->lock);
		return 0;
	}
	if (ev.wear != G2_WEAR_NO_CHANGE) {
		data->wear = ev.wear;
	}
	g2_touch_cb cb = data->cb;
	void *ctx = data->ctx;

	k_mutex_unlock(&data->lock);
	if (cb) {
		cb(dev, &ev, ctx);
	}
	return 0;
}

static void report_work(struct k_work *work)
{
	struct g2_touch_data *data = CONTAINER_OF(work, struct g2_touch_data, work);

	(void)g2_touch_service(data->dev);
}

static void attn_isr(const struct device *port, struct gpio_callback *gcb, uint32_t pins)
{
	struct g2_touch_data *data = CONTAINER_OF(gcb, struct g2_touch_data, attn_cb);

	ARG_UNUSED(port);
	ARG_UNUSED(pins);
	k_work_submit(&data->work);
}

int g2_touch_set_callback(const struct device *dev, g2_touch_cb cb, void *ctx)
{
	struct g2_touch_data *data = dev->data;

	k_mutex_lock(&data->lock, K_FOREVER);
	data->cb = cb;
	data->ctx = ctx;
	k_mutex_unlock(&data->lock);
	return 0;
}

uint32_t g2_touch_version(const struct device *dev)
{
	return ((struct g2_touch_data *)dev->data)->version;
}

uint8_t g2_touch_wear(const struct device *dev)
{
	return ((struct g2_touch_data *)dev->data)->wear;
}

int g2_touch_save_baseline(const struct device *dev)
{
	struct g2_touch_data *data = dev->data;
	int err;

	k_mutex_lock(&data->lock, K_FOREVER);
	err = psoc_cmd(dev, CMD_SAVE_BASELINE, NULL, 0);
	k_mutex_unlock(&data->lock);
	return err;
}

static int attn_irq(const struct device *dev, bool on)
{
	const struct g2_touch_config *cfg = dev->config;

	return gpio_pin_interrupt_configure_dt(&cfg->attn,
					       on ? GPIO_INT_EDGE_TO_ACTIVE : GPIO_INT_DISABLE);
}

static int g2_touch_pm_action(const struct device *dev, enum pm_device_action action)
{
	struct g2_touch_data *data = dev->data;

	switch (action) {
	case PM_DEVICE_ACTION_SUSPEND:
		k_mutex_lock(&data->lock, K_FOREVER);
		data->suspended = true;
		k_mutex_unlock(&data->lock);
		return attn_irq(dev, false);
	case PM_DEVICE_ACTION_RESUME:
		k_mutex_lock(&data->lock, K_FOREVER);
		data->suspended = false;
		k_mutex_unlock(&data->lock);
		/* A report published while suspended keeps the line low; read it now. */
		k_work_submit(&data->work);
		return attn_irq(dev, true);
	default:
		return -ENOTSUP;
	}
}

static int g2_touch_init(const struct device *dev)
{
	const struct g2_touch_config *cfg = dev->config;
	struct g2_touch_data *data = dev->data;
	uint8_t lp[2] = {0};
	int err;

	data->dev = dev;
	k_mutex_init(&data->lock);
	k_work_init(&data->work, report_work);
	if (!i2c_is_ready_dt(&cfg->i2c) || !gpio_is_ready_dt(&cfg->attn) ||
	    !gpio_is_ready_dt(&cfg->reset)) {
		return -ENODEV;
	}
	err = gpio_pin_configure_dt(&cfg->reset, GPIO_OUTPUT_INACTIVE);
	err = err ? err : gpio_pin_configure_dt(&cfg->attn, GPIO_INPUT);
	if (err) {
		return err;
	}
	psoc_reset(dev);
	err = read_version(dev);
	if (err) {
		LOG_WRN("PSoC version read failed (%d); continuing, never updating", err);
	} else {
		LOG_INF("PSoC firmware %08x", data->version);
	}
	if (psoc_cmd(dev, CMD_READ_LONGPRESS, lp, sizeof(lp)) == 0) {
		LOG_INF("long press %u ms", sys_get_le16(lp));
	}
	gpio_init_callback(&data->attn_cb, attn_isr, BIT(cfg->attn.pin));
	err = gpio_add_callback_dt(&cfg->attn, &data->attn_cb);
	if (err) {
		return err;
	}
	return pm_device_driver_init(dev, g2_touch_pm_action);
}

#define G2_TOUCH_DEFINE(inst)                                                                      \
	static struct g2_touch_data g2_touch_data_##inst;                                          \
	static const struct g2_touch_config g2_touch_config_##inst = {                             \
		.i2c = I2C_DT_SPEC_INST_GET(inst),                                                 \
		.attn = GPIO_DT_SPEC_INST_GET(inst, attn_gpios),                                   \
		.reset = GPIO_DT_SPEC_INST_GET(inst, reset_gpios),                                 \
		.settle_ms = DT_INST_PROP(inst, reset_settle_ms),                                  \
	};                                                                                         \
	PM_DEVICE_DT_INST_DEFINE(inst, g2_touch_pm_action);                                        \
	DEVICE_DT_INST_DEFINE(inst, g2_touch_init, PM_DEVICE_DT_INST_GET(inst),                    \
			      &g2_touch_data_##inst, &g2_touch_config_##inst, POST_KERNEL,         \
			      CONFIG_WISP_DRIVERS_INIT_PRIORITY, NULL);

DT_INST_FOREACH_STATUS_OKAY(G2_TOUCH_DEFINE)
