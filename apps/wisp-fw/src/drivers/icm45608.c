/*
 * SPDX-License-Identifier: MIT
 *
 * TDK ICM-45608 6-axis IMU on I2C (Zephyr sensor API). Written from TDK's ICM-456xx register
 * map (inv_imu_regmap_le.h names and addresses, BSD-3) and the G2 facts in docs/wisp/hardware.md
 * ("IMU"); no code from elsewhere.
 *
 * Model: everything off until an attribute turns a sensor on (README W9).
 *   SENSOR_ATTR_SAMPLING_FREQUENCY on SENSOR_CHAN_ACCEL_XYZ / GYRO_XYZ: 0 = off, else the
 *   nearest ODR from 25 to 800 Hz (stock's range, codes 11..6). Accel runs in low-power mode
 *   up to 400 Hz, low-noise above; the gyro runs low-noise.
 *   Data-ready trigger on INT1 (GPIO38, rising, push-pull pulsed active-high, as stock).
 * Power: PM suspend turns both sensors off and drops the IMU rail (GPIO129), so the part draws
 * nothing; resume powers it, resets it and restores the configuration. No polling.
 */

#define DT_DRV_COMPAT invensense_icm45608

#include <zephyr/device.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/pm/device.h>
#include <zephyr/sys/byteorder.h>

LOG_MODULE_REGISTER(icm45608, CONFIG_SENSOR_LOG_LEVEL);

#define REG_DATA          0x00 /* accel X..Z, gyro X..Z, temp: 7 x int16 little-endian */
#define REG_PWR_MGMT0     0x10
#define REG_INT1_CONFIG0  0x16
#define REG_INT1_CONFIG2  0x18
#define REG_INT1_STATUS0  0x19
#define REG_ACCEL_CONFIG0 0x1B
#define REG_GYRO_CONFIG0  0x1C
#define REG_WHO_AM_I      0x72
#define REG_MISC2         0x7F

#define WHO_AM_I_45608    0x81
#define MISC2_SOFT_RST    BIT(1)
#define INT1_STATUS0_RESET_DONE BIT(7)
#define INT1_STATUS0_DRDY BIT(2)
#define INT1_CONFIG0_DRDY BIT(2)
#define INT1_CONFIG2_PP_PULSE_HIGH 0x01

#define MODE_OFF 0
#define MODE_LP  2
#define MODE_LN  3

struct icm45608_config {
	struct i2c_dt_spec i2c;
	struct gpio_dt_spec int1;
	struct gpio_dt_spec supply;
	uint8_t accel_fs_code, gyro_fs_code;
	uint16_t accel_fs_g, gyro_fs_dps;
};

struct icm45608_data {
	const struct device *dev;
	int16_t raw[7];
	uint8_t accel_odr, gyro_odr; /* ODR codes, 0 = off */
	bool suspended;
	struct gpio_callback int_cb;
	struct k_work work;
	sensor_trigger_handler_t drdy_handler;
	const struct sensor_trigger *drdy_trig;
};

static int wr(const struct device *dev, uint8_t reg, uint8_t val)
{
	const struct icm45608_config *cfg = dev->config;

	return i2c_reg_write_byte_dt(&cfg->i2c, reg, val);
}

static int rd(const struct device *dev, uint8_t reg, uint8_t *buf, size_t len)
{
	const struct icm45608_config *cfg = dev->config;

	return i2c_burst_read_dt(&cfg->i2c, reg, buf, len);
}

/* ODR code for a rate in Hz: 6 = 800, 7 = 400, 8 = 200, 9 = 100, 10 = 50, 11 = 25. */
static uint8_t odr_code(int32_t hz)
{
	static const uint16_t rates[] = {800, 400, 200, 100, 50, 25};

	if (hz <= 0) {
		return 0;
	}
	for (int i = (int)ARRAY_SIZE(rates) - 1; i >= 0; i--) {
		if (hz <= rates[i]) {
			return (uint8_t)(6 + i);
		}
	}
	return 6;
}

static int apply_modes(const struct device *dev)
{
	const struct icm45608_config *cfg = dev->config;
	struct icm45608_data *data = dev->data;
	uint8_t accel_mode = data->accel_odr == 0 ? MODE_OFF : data->accel_odr >= 7 ? MODE_LP : MODE_LN;
	uint8_t gyro_mode = data->gyro_odr == 0 ? MODE_OFF : MODE_LN;
	int err;

	err = wr(dev, REG_ACCEL_CONFIG0,
		 (uint8_t)(cfg->accel_fs_code << 4 | (data->accel_odr ? data->accel_odr : 11)));
	err = err ? err : wr(dev, REG_GYRO_CONFIG0,
			     (uint8_t)(cfg->gyro_fs_code << 4 | (data->gyro_odr ? data->gyro_odr : 11)));
	err = err ? err : wr(dev, REG_PWR_MGMT0, (uint8_t)(gyro_mode << 2 | accel_mode));
	return err;
}

static int chip_up(const struct device *dev)
{
	const struct icm45608_config *cfg = dev->config;
	struct icm45608_data *data = dev->data;
	uint8_t v = 0;
	int err;

	if (cfg->supply.port) {
		/* Stock: rail off >= 100 ms, on, wait 5 ms. */
		gpio_pin_set_dt(&cfg->supply, 0);
		k_msleep(100);
		gpio_pin_set_dt(&cfg->supply, 1);
		k_msleep(5);
	}
	err = rd(dev, REG_WHO_AM_I, &v, 1);
	if (err || v != WHO_AM_I_45608) {
		LOG_ERR("WHO_AM_I 0x%02x (err %d), want 0x%02x", v, err, WHO_AM_I_45608);
		return err ? err : -ENODEV;
	}
	err = wr(dev, REG_MISC2, MISC2_SOFT_RST);
	if (err) {
		return err;
	}
	k_msleep(3);
	err = rd(dev, REG_INT1_STATUS0, &v, 1);
	if (err) {
		return err;
	}
	if (!(v & INT1_STATUS0_RESET_DONE)) {
		LOG_WRN("soft reset not confirmed (INT1_STATUS0 0x%02x)", v);
	}
	err = wr(dev, REG_INT1_CONFIG2, INT1_CONFIG2_PP_PULSE_HIGH);
	err = err ? err : wr(dev, REG_INT1_CONFIG0, data->drdy_handler ? INT1_CONFIG0_DRDY : 0);
	return err ? err : apply_modes(dev);
}

static int icm45608_attr_set(const struct device *dev, enum sensor_channel chan,
			     enum sensor_attribute attr, const struct sensor_value *val)
{
	struct icm45608_data *data = dev->data;

	if (attr != SENSOR_ATTR_SAMPLING_FREQUENCY) {
		return -ENOTSUP;
	}
	switch (chan) {
	case SENSOR_CHAN_ACCEL_XYZ:
		data->accel_odr = odr_code(val->val1);
		break;
	case SENSOR_CHAN_GYRO_XYZ:
		data->gyro_odr = odr_code(val->val1);
		break;
	default:
		return -ENOTSUP;
	}
	return data->suspended ? 0 : apply_modes(dev);
}

static int icm45608_sample_fetch(const struct device *dev, enum sensor_channel chan)
{
	struct icm45608_data *data = dev->data;
	uint8_t buf[14];
	int err;

	ARG_UNUSED(chan);
	if (data->suspended) {
		return -EBUSY;
	}
	err = rd(dev, REG_DATA, buf, sizeof(buf));
	if (err) {
		return err;
	}
	for (int i = 0; i < 7; i++) {
		data->raw[i] = (int16_t)sys_get_le16(&buf[2 * i]);
	}
	return 0;
}

static void to_value(int64_t micro, struct sensor_value *v)
{
	v->val1 = (int32_t)(micro / 1000000);
	v->val2 = (int32_t)(micro % 1000000);
}

static int icm45608_channel_get(const struct device *dev, enum sensor_channel chan,
				struct sensor_value *val)
{
	const struct icm45608_config *cfg = dev->config;
	struct icm45608_data *data = dev->data;
	int first, n;
	bool gyro = false;

	switch (chan) {
	case SENSOR_CHAN_ACCEL_X: first = 0; n = 1; break;
	case SENSOR_CHAN_ACCEL_Y: first = 1; n = 1; break;
	case SENSOR_CHAN_ACCEL_Z: first = 2; n = 1; break;
	case SENSOR_CHAN_ACCEL_XYZ: first = 0; n = 3; break;
	case SENSOR_CHAN_GYRO_X: first = 3; n = 1; gyro = true; break;
	case SENSOR_CHAN_GYRO_Y: first = 4; n = 1; gyro = true; break;
	case SENSOR_CHAN_GYRO_Z: first = 5; n = 1; gyro = true; break;
	case SENSOR_CHAN_GYRO_XYZ: first = 3; n = 3; gyro = true; break;
	case SENSOR_CHAN_DIE_TEMP:
		/* °C = raw / 128 + 25 */
		to_value((int64_t)data->raw[6] * 1000000 / 128 + 25000000, val);
		return 0;
	default:
		return -ENOTSUP;
	}
	for (int i = 0; i < n; i++) {
		int64_t raw = data->raw[first + i];

		if (gyro) {
			/* rad/s: raw * fs / 32768 * pi / 180 */
			to_value(raw * cfg->gyro_fs_dps * 17453LL / 32768, &val[i]);
		} else {
			/* m/s²: raw * fs / 32768 * g */
			to_value(raw * cfg->accel_fs_g * 9806650LL / 32768, &val[i]);
		}
	}
	return 0;
}

static void drdy_work(struct k_work *work)
{
	struct icm45608_data *data = CONTAINER_OF(work, struct icm45608_data, work);
	uint8_t st;

	/* Reading INT1_STATUS0 clears it. */
	if (rd(data->dev, REG_INT1_STATUS0, &st, 1) == 0 && (st & INT1_STATUS0_DRDY) &&
	    data->drdy_handler) {
		data->drdy_handler(data->dev, data->drdy_trig);
	}
}

static void int1_isr(const struct device *port, struct gpio_callback *cb, uint32_t pins)
{
	struct icm45608_data *data = CONTAINER_OF(cb, struct icm45608_data, int_cb);

	ARG_UNUSED(port);
	ARG_UNUSED(pins);
	k_work_submit(&data->work);
}

static int icm45608_trigger_set(const struct device *dev, const struct sensor_trigger *trig,
				sensor_trigger_handler_t handler)
{
	const struct icm45608_config *cfg = dev->config;
	struct icm45608_data *data = dev->data;
	int err;

	if (trig->type != SENSOR_TRIG_DATA_READY || !cfg->int1.port) {
		return -ENOTSUP;
	}
	data->drdy_handler = handler;
	data->drdy_trig = trig;
	if (data->suspended) {
		return 0;
	}
	err = wr(dev, REG_INT1_CONFIG0, handler ? INT1_CONFIG0_DRDY : 0);
	return err ? err
		   : gpio_pin_interrupt_configure_dt(&cfg->int1, handler ? GPIO_INT_EDGE_TO_ACTIVE
									: GPIO_INT_DISABLE);
}

static DEVICE_API(sensor, icm45608_api) = {
	.attr_set = icm45608_attr_set,
	.sample_fetch = icm45608_sample_fetch,
	.channel_get = icm45608_channel_get,
	.trigger_set = icm45608_trigger_set,
};

static int icm45608_pm_action(const struct device *dev, enum pm_device_action action)
{
	const struct icm45608_config *cfg = dev->config;
	struct icm45608_data *data = dev->data;
	int err;

	switch (action) {
	case PM_DEVICE_ACTION_SUSPEND:
		data->suspended = true;
		if (cfg->int1.port) {
			gpio_pin_interrupt_configure_dt(&cfg->int1, GPIO_INT_DISABLE);
		}
		(void)wr(dev, REG_PWR_MGMT0, 0);
		if (cfg->supply.port) {
			gpio_pin_set_dt(&cfg->supply, 0);
		}
		return 0;
	case PM_DEVICE_ACTION_RESUME:
		err = chip_up(dev);
		if (err) {
			return err;
		}
		data->suspended = false;
		if (cfg->int1.port && data->drdy_handler) {
			gpio_pin_interrupt_configure_dt(&cfg->int1, GPIO_INT_EDGE_TO_ACTIVE);
		}
		return 0;
	default:
		return -ENOTSUP;
	}
}

static int icm45608_init(const struct device *dev)
{
	const struct icm45608_config *cfg = dev->config;
	struct icm45608_data *data = dev->data;
	int err;

	data->dev = dev;
	data->suspended = true;
	k_work_init(&data->work, drdy_work);
	if (!i2c_is_ready_dt(&cfg->i2c)) {
		return -ENODEV;
	}
	if (cfg->supply.port) {
		err = gpio_pin_configure_dt(&cfg->supply, GPIO_OUTPUT_INACTIVE);
		if (err) {
			return err;
		}
	}
	if (cfg->int1.port) {
		err = gpio_pin_configure_dt(&cfg->int1, GPIO_INPUT);
		if (err) {
			return err;
		}
		gpio_init_callback(&data->int_cb, int1_isr, BIT(cfg->int1.pin));
		err = gpio_add_callback_dt(&cfg->int1, &data->int_cb);
		if (err) {
			return err;
		}
	}
	return pm_device_driver_init(dev, icm45608_pm_action);
}

/* FS codes: accel 1 = ±16 g, 2 = ±8, 3 = ±4, 4 = ±2; gyro 1 = ±2000 dps, 2 = 1000, 3 = 500,
 * 4 = 250. Code 0 (±32 g / ±4000 dps) does not exist on the 45608. */
#define ACCEL_FS_CODE(g)   ((g) == 16 ? 1 : (g) == 8 ? 2 : (g) == 4 ? 3 : 4)
#define GYRO_FS_CODE(dps)  ((dps) == 2000 ? 1 : (dps) == 1000 ? 2 : (dps) == 500 ? 3 : 4)

#define ICM45608_DEFINE(inst)                                                                      \
	static struct icm45608_data icm45608_data_##inst;                                          \
	static const struct icm45608_config icm45608_config_##inst = {                             \
		.i2c = I2C_DT_SPEC_INST_GET(inst),                                                 \
		.int1 = GPIO_DT_SPEC_INST_GET_OR(inst, int_gpios, {0}),                            \
		.supply = GPIO_DT_SPEC_INST_GET_OR(inst, supply_gpios, {0}),                       \
		.accel_fs_g = DT_INST_PROP(inst, accel_fs_g),                                      \
		.gyro_fs_dps = DT_INST_PROP(inst, gyro_fs_dps),                                    \
		.accel_fs_code = ACCEL_FS_CODE(DT_INST_PROP(inst, accel_fs_g)),                    \
		.gyro_fs_code = GYRO_FS_CODE(DT_INST_PROP(inst, gyro_fs_dps)),                     \
	};                                                                                         \
	PM_DEVICE_DT_INST_DEFINE(inst, icm45608_pm_action);                                        \
	SENSOR_DEVICE_DT_INST_DEFINE(inst, icm45608_init, PM_DEVICE_DT_INST_GET(inst),             \
				     &icm45608_data_##inst, &icm45608_config_##inst, POST_KERNEL,  \
				     CONFIG_SENSOR_INIT_PRIORITY, &icm45608_api);

DT_INST_FOREACH_STATUS_OKAY(ICM45608_DEFINE)
