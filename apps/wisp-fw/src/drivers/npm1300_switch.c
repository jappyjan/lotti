/*
 * SPDX-License-Identifier: MIT
 *
 * The panel's nPM1300 rails, switched the way stock switches them and nothing more (rung4.md W25).
 *
 * Stock turns the JBD4010's rails on with LDSW2 then BUCK1 and off in reverse (hardware.md
 * "Display"): task writes, with the rails' voltages and modes configured long before. native-0
 * kept every Zephyr PMIC driver off (G12: their init would write SHIP/LPRESET, GPIO modes, BUCK2,
 * LDO1 and the whole charger from our DTS). This driver is the panel's only way to its rails, and
 * it writes only these task registers:
 *
 *   BUCK1 on 04 00 01, off 04 01 01        LDSW2 on 08 02 01, off 08 03 01
 *
 * wisp_npm1300_switch_force_off() writes the same disable task, after the same gate, whatever the
 * refcount says: the PMIC keeps a rail on across every Apollo reset, so the boot screen turns both
 * off first at boot (a reset inside its 60 s window would otherwise leave them on).
 *
 * Before an enable it reads the rail's configuration and refuses (-EACCES, nothing written) unless
 * it is stock's (W21's snapshot): BUCK1 VOUT_NORM = the expected code (0x01, the JBD4010's ~1.1 V)
 * and SW_CTRL = 0x03 (software voltage, so VOUT_NORM is what the rail outputs, not the VSET pin);
 * LDSW2 LDOSEL = 0x00 (load switch). After a PMIC power cycle (W24) these read their power-on
 * values, the gate fails, and the panel stays off instead of getting an unknown voltage.
 */
#define DT_DRV_COMPAT wisp_npm1300_switch

#include <errno.h>

#include <zephyr/device.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/regulator.h>
#include <zephyr/kernel.h>

enum rail { RAIL_BUCK1, RAIL_LDSW2 };

struct sw_config {
	struct regulator_common_config common;
	struct i2c_dt_spec i2c;
	enum rail rail;
	uint8_t expect_vout;
};

struct sw_data {
	struct regulator_common_data common;
	int8_t gate; /* the last gate result: 0, -EACCES or a bus error */
};

static int reg_read(const struct sw_config *cfg, uint8_t base, uint8_t off, uint8_t *v)
{
	const uint8_t addr[2] = {base, off};

	return i2c_write_read_dt(&cfg->i2c, addr, sizeof(addr), v, 1);
}

static int task(const struct sw_config *cfg, uint8_t base, uint8_t off)
{
	const uint8_t buf[3] = {base, off, 1};

	return i2c_write_dt(&cfg->i2c, buf, sizeof(buf));
}

/* Stock's configuration, read back: 0, -EACCES (not stock's) or a bus error. */
static int gate(const struct sw_config *cfg)
{
	uint8_t a = 0xFF, b = 0xFF;
	int err;

	if (cfg->rail == RAIL_BUCK1) {
		err = reg_read(cfg, 0x04, 0x08, &a); /* BUCK1.VOUT_NORM */
		err = err ? err : reg_read(cfg, 0x04, 0x0F, &b); /* BUCK.SW_CTRL */
		return err ? err : (a == cfg->expect_vout && b == 0x03) ? 0 : -EACCES;
	}
	err = reg_read(cfg, 0x08, 0x09, &a); /* LDSW2.LDOSEL */
	return err ? err : a == 0x00 ? 0 : -EACCES;
}

static int sw_enable(const struct device *dev)
{
	const struct sw_config *cfg = dev->config;
	struct sw_data *data = dev->data;
	int err = gate(cfg);

	data->gate = (int8_t)err;
	if (err) {
		return err;
	}
	return cfg->rail == RAIL_BUCK1 ? task(cfg, 0x04, 0x00) : task(cfg, 0x08, 0x02);
}

static int sw_disable(const struct device *dev)
{
	const struct sw_config *cfg = dev->config;

	return cfg->rail == RAIL_BUCK1 ? task(cfg, 0x04, 0x01) : task(cfg, 0x08, 0x03);
}

static DEVICE_API(regulator, sw_api) = {
	.enable = sw_enable,
	.disable = sw_disable,
};

static int sw_init(const struct device *dev)
{
	const struct sw_config *cfg = dev->config;

	regulator_common_data_init(dev);
	if (!i2c_is_ready_dt(&cfg->i2c)) {
		return -ENODEV;
	}
	/* Off as far as the refcount goes; nothing is read or written here. */
	return regulator_common_init(dev, false);
}

int wisp_npm1300_switch_force_off(const struct device *dev)
{
	const struct sw_config *cfg = dev->config;
	int err = gate(cfg);

	((struct sw_data *)dev->data)->gate = (int8_t)err;
	return err ? err : sw_disable(dev);
}

int wisp_npm1300_switch_check(const struct device *dev)
{
	int err = gate(dev->config);

	((struct sw_data *)dev->data)->gate = (int8_t)err;
	return err;
}

#define SW_RAIL(n) (DT_INST_ENUM_IDX(n, rail) == 0 ? RAIL_BUCK1 : RAIL_LDSW2)

#define SW_DEFINE(n)                                                                               \
	BUILD_ASSERT(DT_INST_ENUM_IDX(n, rail) != 0 || DT_INST_NODE_HAS_PROP(n, expect_vout),      \
		     "buck1 needs expect-vout");                                                   \
	static struct sw_data sw_data_##n;                                                         \
	static const struct sw_config sw_config_##n = {                                            \
		.common = REGULATOR_DT_INST_COMMON_CONFIG_INIT(n),                                 \
		.i2c = I2C_DT_SPEC_GET(DT_INST_PARENT(n)),                                         \
		.rail = SW_RAIL(n),                                                                \
		.expect_vout = DT_INST_PROP_OR(n, expect_vout, 0xFF),                              \
	};                                                                                         \
	DEVICE_DT_INST_DEFINE(n, sw_init, NULL, &sw_data_##n, &sw_config_##n, POST_KERNEL,         \
			      CONFIG_WISP_DRIVERS_INIT_PRIORITY, &sw_api);

DT_INST_FOREACH_STATUS_OKAY(SW_DEFINE)
