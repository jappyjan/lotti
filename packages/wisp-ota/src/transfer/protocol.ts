// Stock OTA import protocol (phone → glasses), sid 0xC0 control / 0xC1 data,
// as implemented by the stock 2.2.6.10 main app. Every fact names its source;
// [C] = confirmed (hardware-validated in webflasher, or pinned in openCFW's
// reconstruction of the stock code), [I] = inferred.
//
//   O  = openCFW (MIT) `g2/src/apollo-main/app/a-02-ota-service/ota_service_file_parse.c`
//        (`_fileCmdParse` 0x445660, `_fileRawDataParse` 0x446d40, 2.2.6.10)
//   T  = openCFW `g2/src/apollo-main/app/a-12-ota-transport/ota_transport.c`
//        (`OTA_ReceivePacket` 0x48d8d8, `OTA_SendPacket` 0x48de40)
//   P  = openCFW `g2/docs/reference/protocols.md` §5–6
//   W  = webflasher (MIT) `src/lib/g2BleOta.js` (G2BleOtaSession, hardware-validated on 2.2.6.10)

/** Control: `[subcommand, …]`, always a single packet [C T: `rx_single_frame`]. */
export const SID_OTA_CONTROL = 0xc0;
/** Raw data: one 4 KiB block per message, CRC-16 over the block [C T]. */
export const SID_OTA_DATA = 0xc1;

/**
 * Subcommands (first payload byte of a 0xC0 message, first byte of every reply).
 * Names follow the stock log strings `eOTATransmitCID_OTA_TRANSMIT_*` [C O].
 */
export const OtaSubcommand = {
  /** Resets the import state, closes a stale file, heals the fs, forces fast connection params. Reply `{0, status}` [C O]. */
  start: 0x00,
  /** Carries the 128-byte component header; deletes and re-creates the target file. Reply `{1, status}` [C O]. */
  information: 0x01,
  /**
   * Arms raw-data parsing and opens the 0x1020-byte reassembly buffer for the 0xC1
   * message that follows with the same seq. No reply of its own; the block is
   * answered as `{2, status}` on sid 0xC1 [C O, T, W `sendBlock`].
   */
  file: 0x02,
  /** Closes the file and checks size + CRC-32C. Reply `{3, status}` [C O]. */
  resultCheck: 0x03,
  /**
   * Not sent by the phone: after a passing RESULT_CHECK of the main image the
   * glasses write the update flag 0x55555555 and notify `{4, 9 SYS_RESTART}`,
   * then disconnect after 3000 ms and reset into the Even bootloader [C O].
   */
  notify: 0x04,
} as const;

/** Reply status byte [C W `G2_BLE_OTA_STATUS`; meaning per use site in O, T]. */
export const OtaStatus = {
  success: 0,
  /** INFORMATION: header length ≠ 128, path not the per-type target, MRAM address refused. */
  headerError: 1,
  pathError: 2,
  /** Transport: 0xC0 or 0xC1 CRC-16 mismatch, or reassembly overflow. The block never reached the parser. */
  crcError: 3,
  /** Transport: more than 1500 ms between two 0xC1 packets. */
  timeout: 4,
  /** Transport: no reassembly buffer. */
  noResources: 5,
  /** Parser: file write or read-back failed. Stock **deleted the staging file** and reset the session. */
  flashWriteError: 6,
  /** RESULT_CHECK: CRC-32C or size mismatch (stock deletes the file), or no file open. */
  checkFail: 7,
  /** RESULT_CHECK passed for the main image; the flag write follows. */
  updating: 8,
  /** NOTIFY after the flag write: the temple resets in 3 s. */
  sysRestart: 9,
  /** START refused: closing a stale file failed or the filesystem heal failed. */
  fail: 10,
} as const;

export const OTA_STATUS_NAMES: Readonly<Record<number, string>> = {
  0: 'SUCCESS',
  1: 'HEADER_ERR',
  2: 'PATH_ERR',
  3: 'CRC_ERR',
  4: 'TIMEOUT',
  5: 'NO_RESOURCES',
  6: 'FLASH_WRITE_ERR',
  7: 'CHECK_FAIL',
  8: 'UPDATING',
  9: 'SYS_RESTART',
  10: 'FAIL',
};

export function otaStatusName(status: number): string {
  return (
    OTA_STATUS_NAMES[status] ?? `0x${status.toString(16).padStart(2, '0')}`
  );
}

/**
 * Transport-level rejections of one block: the 0xC1 message was dropped before
 * the parser saw it, so the parser's offset did not move and the same block may
 * be sent again [C T: `rx_fail`, `semantic_OtaNotifyStatus3/4/5`; W "the
 * rejected block did not advance and may be sent again"].
 */
export const BLOCK_RETRYABLE_STATUSES: ReadonlySet<number> = new Set([
  OtaStatus.crcError,
  OtaStatus.timeout,
  OtaStatus.noResources,
]);

/** Block size: the stock parser's chunk and the 0x1020-byte reassembly buffer hold 4096 + CRC [C O `OTA_CHUNK`, T, W]. */
export const OTA_BLOCK_SIZE = 4096;
/** The INFORMATION payload is the EVENOTA component header [C O `OTA_HEADER_LENGTH`]. */
export const OTA_HEADER_SIZE = 128;
/** The stock receiver times out a 0xC1 message after 1500 ms between packets [C T]. */
export const OTA_INTERPACKET_TIMEOUT_MS = 1500;
/** After NOTIFY the stock app disconnects after this delay and resets [C O]. */
export const OTA_RESTART_DELAY_MS = 3000;

/**
 * The OTA service lives on its own GATT service; heartbeats go to the control
 * characteristic [C W: OTA frames on `…0001` (service `…1001`), acks on `…0002`,
 * heartbeat on `…5401`].
 */
export const GATT_UUID_BASE = '00002760-08c2-11e1-9073-0e8ac72e';
export const GATT_OTA_SERVICE = `${GATT_UUID_BASE}1001`;
export const GATT_OTA_WRITE = `${GATT_UUID_BASE}0001`;
export const GATT_OTA_NOTIFY = `${GATT_UUID_BASE}0002`;
export const GATT_CONTROL_SERVICE = `${GATT_UUID_BASE}5450`;
export const GATT_CONTROL_WRITE = `${GATT_UUID_BASE}5401`;
export const GATT_CONTROL_NOTIFY = `${GATT_UUID_BASE}5402`;

/**
 * Device-config heartbeat (sid 0x80, `{1: 14 heartbeat, 2: magic 0x26, 13: {}}`),
 * keeps the 30 s dev-config session timer alive during a long transfer
 * [C W `HEARTBEAT_PAYLOAD`; P §4 sid 0x80 "14 heartbeat (30 s timer)"].
 */
export const SID_DEV_CONFIG = 0x80;
export const HEARTBEAT_PAYLOAD: readonly number[] = [
  0x08, 0x0e, 0x10, 0x26, 0x6a, 0x00,
];

export interface StockOtaTiming {
  /** Wait for a START / INFORMATION / RESULT_CHECK reply [W `G2_BLE_CONTROL_ACK_TIMEOUT_MS` 8000]. */
  controlAckTimeoutMs: number;
  /** Wait for a block reply [W `G2_BLE_BLOCK_ACK_TIMEOUT_MS` 4000]. */
  blockAckTimeoutMs: number;
  /** Wait for NOTIFY `{4, 9}` after UPDATING; the temple resets 3 s after it. */
  notifyTimeoutMs: number;
  /** Heartbeat period, well inside the 30 s timer [W 12000]. */
  heartbeatIntervalMs: number;
  /** Pause before a whole-component restart [W `componentRetrySettleMs` 1500, ≥ the 1500 ms receiver timeout]. */
  restartSettleMs: number;
}

export const DEFAULT_TIMING: Readonly<StockOtaTiming> = {
  controlAckTimeoutMs: 8000,
  blockAckTimeoutMs: 4000,
  notifyTimeoutMs: 5000,
  heartbeatIntervalMs: 12000,
  restartSettleMs: 1500,
};

export interface StockOtaLimits {
  /** START sends without a reply before giving up [W `G2_BLE_BEGIN_ATTEMPTS` 3]. */
  startAttempts: number;
  /** Explicit transport NAKs of one block before giving up [W `G2_BLE_BLOCK_NAK_ATTEMPTS` 3]. */
  blockAttempts: number;
  /** Whole-component runs (INFORMATION → blocks → RESULT_CHECK) [W `G2_BLE_COMPONENT_ATTEMPTS` 3]. */
  componentAttempts: number;
}

export const LIMITS: Readonly<StockOtaLimits> = {
  startAttempts: 3,
  blockAttempts: 3,
  componentAttempts: 3,
};
