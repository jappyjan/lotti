// Stock OTA sender (phone → one temple over the stock 0xC0/0xC1 protocol).
// Transport-agnostic: callers provide a StockLink. No BLE code in this package.

export * from './link.ts';
export * from './protocol.ts';
export {
  prepareStockOta,
  sendStockOta,
  StockOtaError,
  StockOtaTransfer,
  type StockIntact,
  type StockOtaErrorCode,
  type StockOtaOptions,
  type StockOtaPhase,
  type StockOtaProgress,
  type StockOtaResult,
  type StockOtaState,
  type StockOtaStats,
} from './sender.ts';
export {
  crc16CcittFalse,
  encodeTpl,
  TplAssembler,
  TPL_CHUNK_SIZE,
  TPL_FROM_GLASSES,
  TPL_HEADER_SIZE,
  TPL_MAGIC,
  TPL_MAX_PACKET,
  TPL_TO_GLASSES,
  type TplFeedResult,
  type TplMessage,
} from './tpl.ts';
