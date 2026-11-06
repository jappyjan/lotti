/*
 * SPDX-License-Identifier: MIT
 *
 * The Wisp GATT service on Zephyr: transport only (docs/wisp/protocol.md "Links").
 *
 *   service cf099bf1-f34e-49e2-b353-7f20e02243bc
 *     RX  …bf2  write without response (and write): phone → glasses, a byte stream
 *     TX  …bf3  notify: glasses → phone, cut to ATT MTU - 3
 *
 * Every protocol decision (frames, credits, HELLO, timeouts) is wisp-core's wisp_conn, and
 * every transport decision (chunking, back-pressure, advertising mode, idle drop) is the
 * adapter's (src/link/wisp_link.c, host-tested). This file maps Zephyr's callbacks onto the
 * adapter. All adapter calls run on one work queue thread: callbacks from the Bluetooth threads
 * only set event bits, copy RX bytes into a ring and submit the work. Nothing polls: the work
 * runs on an event or at the adapter's next deadline.
 *
 * One connection at a time (CONFIG_BT_MAX_CONN=1). Advertising runs while nobody is connected;
 * a connection that carries no session for CONFIG_WISP_LINK_IDLE_DROP_MS is dropped, so
 * advertising only stops while a session is up or about to be.
 */

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/ring_buffer.h>

#include "app_version.h"
#include "wisp_ble.h"
#include "wisp_hal.h"
#include "wisp_link.h"

LOG_MODULE_REGISTER(wisp_ble, LOG_LEVEL_INF);

#define WISP_UUID(last) BT_UUID_128_ENCODE(0xcf099bf0 + (last), 0xf34e, 0x49e2, 0xb353, 0x7f20e02243bc)

static const struct bt_uuid_128 svc_uuid = BT_UUID_INIT_128(WISP_UUID(1));
static const struct bt_uuid_128 rx_uuid = BT_UUID_INIT_128(WISP_UUID(2));
static const struct bt_uuid_128 tx_uuid = BT_UUID_INIT_128(WISP_UUID(3));

/* ---- state shared with the Bluetooth threads ---- */

enum {
	EV_CONNECTED = BIT(0),
	EV_DISCONNECTED = BIT(1),
	EV_MTU = BIT(2),
	EV_SUBSCRIPTION = BIT(3),
	EV_TX_DONE = BIT(4),
	EV_RETRY_ADV = BIT(5),
};

static atomic_t events;
static atomic_t in_flight;   /* notifications queued in the stack */
static atomic_t subscribed;  /* TX CCC */
static atomic_t mtu;         /* ATT MTU of the current connection */
static struct bt_conn *cur;  /* set and cleared in the connection callbacks */
static struct k_spinlock rx_lock;
static uint32_t rx_dropped;  /* bytes that found the ring full (the protocol resyncs) */
RING_BUF_DECLARE(rx_ring, CONFIG_WISP_LINK_RX_RING);

static K_THREAD_STACK_DEFINE(link_stack, CONFIG_WISP_LINK_STACK_SIZE);
static struct k_work_q link_wq;
static struct k_work kick;
static struct k_work_delayable timer;

static void submit(uint32_t ev)
{
	atomic_or(&events, (atomic_val_t)ev);
	k_work_submit_to_queue(&link_wq, &kick);
}

/* ---- GATT ---- */

static ssize_t rx_write(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *buf,
			uint16_t len, uint16_t offset, uint8_t flags)
{
	ARG_UNUSED(attr);
	ARG_UNUSED(flags);
	if (offset) {
		return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
	}
	k_spinlock_key_t key = k_spin_lock(&rx_lock);

	if (conn == cur) {
		uint32_t put = ring_buf_put(&rx_ring, buf, len);

		rx_dropped += len - put;
	}
	k_spin_unlock(&rx_lock, key);
	k_work_submit_to_queue(&link_wq, &kick);
	return len;
}

static void tx_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
	ARG_UNUSED(attr);
	atomic_set(&subscribed, value == BT_GATT_CCC_NOTIFY);
	submit(EV_SUBSCRIPTION);
}

BT_GATT_SERVICE_DEFINE(wisp_svc,
	BT_GATT_PRIMARY_SERVICE(&svc_uuid),
	BT_GATT_CHARACTERISTIC(&rx_uuid.uuid, BT_GATT_CHRC_WRITE_WITHOUT_RESP | BT_GATT_CHRC_WRITE,
			       BT_GATT_PERM_WRITE, NULL, rx_write, NULL),
	BT_GATT_CHARACTERISTIC(&tx_uuid.uuid, BT_GATT_CHRC_NOTIFY, BT_GATT_PERM_NONE, NULL, NULL,
			       NULL),
	BT_GATT_CCC(tx_ccc_changed, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE));

/* attrs: 0 service, 1 RX decl, 2 RX value, 3 TX decl, 4 TX value, 5 CCC */
#define TX_VALUE_ATTR (&wisp_svc.attrs[4])

static void att_mtu_updated(struct bt_conn *conn, uint16_t tx, uint16_t rx)
{
	ARG_UNUSED(tx);
	ARG_UNUSED(rx);
	if (conn == cur) {
		atomic_set(&mtu, bt_gatt_get_mtu(conn));
		submit(EV_MTU);
	}
}

static struct bt_gatt_cb gatt_cb = {
	.att_mtu_updated = att_mtu_updated,
};

/* ---- connections ---- */

static void connected(struct bt_conn *conn, uint8_t err)
{
	if (err || cur) {
		return;
	}
	k_spinlock_key_t key = k_spin_lock(&rx_lock);

	cur = bt_conn_ref(conn);
	ring_buf_reset(&rx_ring);
	k_spin_unlock(&rx_lock, key);
	atomic_set(&in_flight, 0);
	atomic_set(&subscribed, 0);
	atomic_set(&mtu, bt_gatt_get_mtu(conn));
	LOG_INF("connected");
	submit(EV_CONNECTED);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	if (conn != cur) {
		return;
	}
	k_spinlock_key_t key = k_spin_lock(&rx_lock);
	struct bt_conn *old = cur;

	cur = NULL;
	ring_buf_reset(&rx_ring);
	k_spin_unlock(&rx_lock, key);
	bt_conn_unref(old); /* outside the lock: it may run the recycled callback */
	atomic_set(&subscribed, 0);
	LOG_INF("disconnected (reason 0x%02x)", reason);
	submit(EV_DISCONNECTED);
}

/* The connection object is free again: advertising can start (it may have failed before). */
static void recycled(void)
{
	submit(EV_RETRY_ADV);
}

static void le_param_updated(struct bt_conn *conn, uint16_t interval, uint16_t latency,
			     uint16_t timeout)
{
	ARG_UNUSED(conn);
	LOG_INF("connection: interval %u.%02u ms, latency %u, timeout %u ms", interval * 5 / 4,
		(interval * 125) % 100, latency, timeout * 10);
}

BT_CONN_CB_DEFINE(wisp_conn_cb) = {
	.connected = connected,
	.disconnected = disconnected,
	.recycled = recycled,
	.le_param_updated = le_param_updated,
};

/* ---- the link HAL (runs on the link work queue) ---- */

static void notify_done(struct bt_conn *conn, void *user_data)
{
	ARG_UNUSED(conn);
	ARG_UNUSED(user_data);
	atomic_dec(&in_flight);
	submit(EV_TX_DONE);
}

/* A reference to the current connection, or NULL (it may go away on a Bluetooth thread). */
static struct bt_conn *cur_ref(void)
{
	k_spinlock_key_t key = k_spin_lock(&rx_lock);
	struct bt_conn *conn = cur ? bt_conn_ref(cur) : NULL;

	k_spin_unlock(&rx_lock, key);
	return conn;
}

static int ble_notify(void *ctx, const uint8_t *data, size_t len)
{
	ARG_UNUSED(ctx);
	/* Stay below the stack's TX buffers, so bt_gatt_notify_cb never waits for one. */
	if (atomic_inc(&in_flight) >= CONFIG_WISP_LINK_TX_IN_FLIGHT) {
		atomic_dec(&in_flight);
		return WISP_HAL_EBUSY;
	}
	struct bt_conn *conn = cur_ref();

	if (!conn) {
		atomic_dec(&in_flight);
		return WISP_HAL_EIO;
	}
	struct bt_gatt_notify_params params = {
		.attr = TX_VALUE_ATTR,
		.data = data,
		.len = (uint16_t)len,
		.func = notify_done,
	};
	int err = bt_gatt_notify_cb(conn, &params);

	bt_conn_unref(conn);
	if (err) {
		atomic_dec(&in_flight);
		return (err == -ENOMEM || err == -ENOBUFS || err == -EAGAIN) ? WISP_HAL_EBUSY
									    : WISP_HAL_EIO;
	}
	return 0;
}

static void ble_disconnect(void *ctx)
{
	ARG_UNUSED(ctx);
	struct bt_conn *conn = cur_ref();

	if (conn) {
		LOG_INF("dropping a connection without a session");
		bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
		bt_conn_unref(conn);
	}
}

static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, WISP_UUID(1)),
};

static const struct bt_data sd[] = {
	BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

static enum wisp_adv_mode adv_want, adv_now;

static void adv_apply(void)
{
	if (adv_now == adv_want) {
		return;
	}
	if (adv_now != WISP_ADV_OFF) {
		bt_le_adv_stop();
		adv_now = WISP_ADV_OFF;
	}
	if (adv_want == WISP_ADV_OFF || cur) {
		return; /* connected: the controller stopped advertising by itself */
	}
	uint16_t interval = adv_want == WISP_ADV_FAST ? CONFIG_WISP_ADV_FAST_INTERVAL
						      : CONFIG_WISP_ADV_SLOW_INTERVAL;
	struct bt_le_adv_param param =
		BT_LE_ADV_PARAM_INIT(BT_LE_ADV_OPT_CONN, interval, interval, NULL);
	int err = bt_le_adv_start(&param, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));

	if (err) {
		/* Typically -ENOMEM until the old connection is recycled; recycled() retries. */
		LOG_DBG("advertising not started yet (%d)", err);
		return;
	}
	adv_now = adv_want;
	LOG_INF("advertising (%s, %u.%03u ms)", adv_want == WISP_ADV_FAST ? "fast" : "slow",
		interval * 625 / 1000, (interval * 625) % 1000);
}

static void ble_advertise(void *ctx, enum wisp_adv_mode mode)
{
	ARG_UNUSED(ctx);
	adv_want = mode;
	adv_apply();
}

static const struct wisp_hal_link_ops ops = {
	.notify = ble_notify,
	.disconnect = ble_disconnect,
	.advertise = ble_advertise,
};

/* ---- the adapter ---- */

static const wisp_session_hello_rsp_t hello = {
	.proto_major = WISP_PROTO_MAJOR,
	.proto_minor = WISP_PROTO_MINOR,
	.max_frame = CONFIG_WISP_LINK_MAX_FRAME,
	.rx_window = CONFIG_WISP_LINK_RX_WINDOW,
	.fw_name = "wisp-native",
	.fw_version = WISP_FW_VERSION,
	.lens = CONFIG_WISP_LENS,
	.caps = 0, /* no drivers behind the core yet: the session only */
	.canvas_w = 640,
	.canvas_h = 480,
	.bpp = 4,
	.session_timeout_ms = CONFIG_WISP_SESSION_TIMEOUT_MS,
};

static struct wisp_link link;
static uint8_t rx_frame[CONFIG_WISP_LINK_MAX_FRAME + WISP_FRAME_OVERHEAD];
static uint8_t tx_ring[CONFIG_WISP_LINK_TX_RING];
static uint8_t tx_queue[CONFIG_WISP_LINK_QUEUE];
static bool sessions_logged;
static bool ready; /* the adapter is initialised (init_handler ran) */

static uint64_t now_us(void)
{
	return k_ticks_to_us_floor64(k_uptime_ticks());
}

static void log_session(void)
{
	bool up = wisp_link_session_active(&link);

	if (up != sessions_logged) {
		sessions_logged = up;
		if (up) {
			LOG_INF("session up: app '%s' (%s)", link.basic.session.peer.app_id,
				link.basic.session.peer.client_name);
		} else {
			LOG_INF("session ended");
		}
	}
}

static void kick_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	if (!ready) {
		return; /* events stay pending; init_handler runs this once it is done */
	}
	uint64_t now = now_us();
	uint32_t ev = (uint32_t)atomic_clear(&events);
	uint8_t buf[256];
	uint32_t n;

	if (ev & EV_DISCONNECTED) {
		wisp_link_disconnected(&link, now);
	}
	if (ev & EV_CONNECTED) {
		wisp_link_connected(&link, (uint16_t)atomic_get(&mtu), now);
	}
	if (ev & EV_MTU) {
		wisp_link_mtu(&link, (uint16_t)atomic_get(&mtu), now);
	}
	if (ev & EV_SUBSCRIPTION) {
		wisp_link_subscribed(&link, atomic_get(&subscribed) != 0, now);
	}
	do {
		k_spinlock_key_t key = k_spin_lock(&rx_lock);

		n = ring_buf_get(&rx_ring, buf, sizeof(buf));
		k_spin_unlock(&rx_lock, key);
		if (n) {
			wisp_link_rx(&link, buf, n, now);
		}
	} while (n);
	static uint32_t dropped_logged;

	if (rx_dropped != dropped_logged) {
		LOG_WRN("RX ring full: %u bytes dropped so far (the protocol resyncs)", rx_dropped);
		dropped_logged = rx_dropped;
	}
	if (ev & EV_TX_DONE) {
		wisp_link_tx_done(&link, now);
	}
	if (ev & EV_RETRY_ADV) {
		adv_apply();
	}
	uint64_t next = wisp_link_tick(&link, now);

	log_session();
	if (next == WISP_CONN_NEVER) {
		k_work_cancel_delayable(&timer);
	} else {
		k_work_reschedule_for_queue(&link_wq, &timer, K_USEC(next - now));
	}
}

static void timer_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	k_work_submit_to_queue(&link_wq, &kick);
}

static void init_handler(struct k_work *work)
{
	ARG_UNUSED(work);
	struct wisp_link_config cfg = {
		.hello = &hello,
		.conn = {
			.rx_buf = rx_frame,
			.rx_cap = sizeof(rx_frame),
			.ring = tx_ring,
			.ring_cap = sizeof(tx_ring),
			.queue = tx_queue,
			.queue_cap = sizeof(tx_queue),
			.rx_window = CONFIG_WISP_LINK_RX_WINDOW,
			.lens = CONFIG_WISP_LENS,
		},
		.fast_adv_ms = CONFIG_WISP_ADV_FAST_MS,
		.idle_drop_ms = CONFIG_WISP_LINK_IDLE_DROP_MS,
	};
	int err = wisp_link_init(&link, &cfg, &ops, NULL, now_us());

	if (err) {
		LOG_ERR("link init failed (%d)", err);
		return;
	}
	ready = true;
	kick_handler(NULL);
}

int wisp_ble_start(void)
{
	static struct k_work init;

	/* The queue first: no Bluetooth callback can then submit to a queue that isn't running. */
	k_work_queue_init(&link_wq);
	k_work_queue_start(&link_wq, link_stack, K_THREAD_STACK_SIZEOF(link_stack),
			   CONFIG_WISP_LINK_PRIORITY, &(struct k_work_queue_config){.name = "wisp_link"});
	k_work_init(&kick, kick_handler);
	k_work_init_delayable(&timer, timer_handler);
	k_work_init(&init, init_handler);

	int err = bt_enable(NULL);

	if (err) {
		LOG_ERR("Bluetooth unavailable (%d): no Wisp link", err);
		return err;
	}
	bt_gatt_cb_register(&gatt_cb);
	k_work_submit_to_queue(&link_wq, &init);
	return 0;
}
