/*
 * SPDX-License-Identifier: MIT
 *
 * TI OPT3007 ambient light sensor (Zephyr sensor API). Written from the TI OPT3001/OPT3007
 * datasheets (register map, config fields); no code from elsewhere.
 *
 * Power: the sensor sits in shutdown (M = 00, about 0.3 µA) except during a fetch, which runs one
 * single-shot conversion (M = 01, about 1.8 µA for 100 or 800 ms) and sleeps the calling thread
 * for the integration time. There is no INT pin on the OPT3007, so nothing polls in the
 * background; the HAL decides how often to fetch. PM suspend forces shutdown.
 */

#define DT_DRV_COMPAT ti_opt3007

#include <zephyr/device.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/byteorder.h>

LOG_MODULE_REGISTER(opt3007, CONFIG_SENSOR_LOG_LEVEL);

#define REG_RESULT  0x00
#define REG_CONFIG  0x01
#define REG_MANUF   0x7E
#define REG_DEVICE  0x7F
#define MANUF_TI    0x5449
#define DEVICE_3001 0x3001

/* CONFIG: RN[15:12] (0xC = automatic full scale), CT[11], M[10:9], OVF[8], CRF[7], ... */
#define CFG_RN_AUTO   (0xCu << 12)
#define CFG_CT_800MS  BIT(11)
#define CFG_M_SHUTDOWN (0u << 9)
#define CFG_M_SINGLE  (1u << 9)
#define CFG_M_MASK    (3u << 9)
#define CFG_CRF       BIT(7)

struct opt3007_config {
	struct i2c_dt_spec i2c;
	uint16_t conv_ms;
};

struct opt3007_data {
	uint16_t raw;
	bool suspended;
};

static int reg_read(const struct device *dev, uint8_t reg, uint16_t *val)
{
	const struct opt3007_config *cfg = dev->config;
	uint8_t buf[2];
	int err = i2c_write_read_dt(&cfg->i2c, &reg, 1, buf, sizeof(buf));

	if (err == 0) {
		*val = sys_get_be16(buf);
	}
	return err;
}

static int reg_write(const struct device *dev, uint8_t reg, uint16_t val)
{
	const struct opt3007_config *cfg = dev->config;
	uint8_t buf[3] = {reg, (uint8_t)(val >> 8), (uint8_t)val};

	return i2c_write_dt(&cfg->i2c, buf, sizeof(buf));
}

static uint16_t cfg_word(const struct opt3007_config *cfg, uint16_t mode)
{
	return (uint16_t)(CFG_RN_AUTO | (cfg->conv_ms == 800 ? CFG_CT_800MS : 0) | mode);
}

static int opt3007_sample_fetch(const struct device *dev, enum sensor_channel chan)
{
	const struct opt3007_config *cfg = dev->config;
	struct opt3007_data *data = dev->data;
	uint16_t c = 0;
	int err;

	if (chan != SENSOR_CHAN_ALL && chan != SENSOR_CHAN_LIGHT) {
		return -ENOTSUP;
	}
	if (data->suspended) {
		return -EBUSY;
	}
	err = reg_write(dev, REG_CONFIG, cfg_word(cfg, CFG_M_SINGLE));
	if (err) {
		return err;
	}
	/* Sleep through the integration (datasheet: 100/800 ms, +10 % worst case), then check
	 * CRF once more after a short grace period. No busy polling. */
	k_msleep(cfg->conv_ms + cfg->conv_ms / 10);
	for (int i = 0; i < 3; i++) {
		err = reg_read(dev, REG_CONFIG, &c);
		if (err || (c & CFG_CRF)) {
			break;
		}
		k_msleep(cfg->conv_ms / 10);
	}
	if (err) {
		return err;
	}
	if (!(c & CFG_CRF)) {
		return -EAGAIN;
	}
	/* Single-shot returns to shutdown by itself (M reads 00 again). */
	return reg_read(dev, REG_RESULT, &data->raw);
}

static int opt3007_channel_get(const struct device *dev, enum sensor_channel chan,
			       struct sensor_value *val)
{
	struct opt3007_data *data = dev->data;

	if (chan != SENSOR_CHAN_LIGHT) {
		return -ENOTSUP;
	}
	/* lux = 0.01 * 2^E * R (E = bits 15..12, R = bits 11..0). */
	uint32_t centi = (uint32_t)(data->raw & 0x0FFFu) << (data->raw >> 12);

	val->val1 = (int32_t)(centi / 100u);
	val->val2 = (int32_t)(centi % 100u) * 10000;
	return 0;
}

static DEVICE_API(sensor, opt3007_api) = {
	.sample_fetch = opt3007_sample_fetch,
	.channel_get = opt3007_channel_get,
};

static int opt3007_pm_action(const struct device *dev, enum pm_device_action action)
{
	const struct opt3007_config *cfg = dev->config;
	struct opt3007_data *data = dev->data;

	switch (action) {
	case PM_DEVICE_ACTION_SUSPEND:
		data->suspended = true;
		return reg_write(dev, REG_CONFIG, cfg_word(cfg, CFG_M_SHUTDOWN));
	case PM_DEVICE_ACTION_RESUME:
		data->suspended = false;
		return 0;
	default:
		return -ENOTSUP;
	}
}

static int opt3007_init(const struct device *dev)
{
	const struct opt3007_config *cfg = dev->config;
	uint16_t v;
	int err;

	if (!i2c_is_ready_dt(&cfg->i2c)) {
		return -ENODEV;
	}
	err = reg_read(dev, REG_MANUF, &v);
	if (err || v != MANUF_TI) {
		LOG_ERR("manufacturer id 0x%04x (err %d)", v, err);
		return err ? err : -ENODEV;
	}
	err = reg_read(dev, REG_DEVICE, &v);
	if (err || v != DEVICE_3001) {
		LOG_ERR("device id 0x%04x (err %d)", v, err);
		return err ? err : -ENODEV;
	}
	/* Start in shutdown: everything off by default (README W9). */
	err = reg_write(dev, REG_CONFIG, cfg_word(cfg, CFG_M_SHUTDOWN));
	if (err) {
		return err;
	}
	return pm_device_driver_init(dev, opt3007_pm_action);
}

#define OPT3007_DEFINE(inst)                                                                       \
	static struct opt3007_data opt3007_data_##inst;                                            \
	static const struct opt3007_config opt3007_config_##inst = {                               \
		.i2c = I2C_DT_SPEC_INST_GET(inst),                                                 \
		.conv_ms = DT_INST_PROP(inst, conversion_time_ms),                                 \
	};                                                                                         \
	PM_DEVICE_DT_INST_DEFINE(inst, opt3007_pm_action);                                         \
	SENSOR_DEVICE_DT_INST_DEFINE(inst, opt3007_init, PM_DEVICE_DT_INST_GET(inst),              \
				     &opt3007_data_##inst, &opt3007_config_##inst, POST_KERNEL,    \
				     CONFIG_SENSOR_INIT_PRIORITY, &opt3007_api);

DT_INST_FOREACH_STATUS_OKAY(OPT3007_DEFINE)
