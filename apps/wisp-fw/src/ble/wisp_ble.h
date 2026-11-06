/*
 * SPDX-License-Identifier: MIT
 *
 * The Wisp GATT service on Zephyr (wisp_ble.c).
 */
#ifndef WISP_BLE_H
#define WISP_BLE_H

/* Enables Bluetooth and starts advertising the Wisp service. Returns 0 or the bt_enable error
 * (the firmware keeps running without a link). */
int wisp_ble_start(void);

#endif /* WISP_BLE_H */
