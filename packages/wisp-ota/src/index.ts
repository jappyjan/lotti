// @wisp/ota: EVENOTA inspector, packer and verifier. Zero runtime
// dependencies, Uint8Array only: runs in Node, browsers and React Native.

export * from './constants.ts';
export { crc32, crc32Bitwise, crc32cMsb, crc32cMsbBitwise } from './crc.ts';
export {
  EvenotaFormatError,
  mainComponents,
  parseBundle,
  parseMainImage,
  type Bundle,
  type Component,
  type ComponentHeader,
  type MainImage,
  type MainPreamble,
  type TocEntry,
} from './parse.ts';
export {
  assertSendable,
  checkMainPayload,
  GUARDS,
  GuardError,
  verifyBundle,
  type ComponentReport,
  type GuardId,
  type GuardResult,
  type GuardScope,
  type GuardSpec,
  type MainReport,
  type VerifyReport,
} from './guards.ts';
export {
  findVersionStrings,
  FIRMWARE_VERSION_PATTERN,
  mainOnlyBundleSize,
  packMain,
  PackError,
  repackMain,
  stockMainOnly,
  stockVersionFromHeader,
  wrapMainImage,
  type PackMainOptions,
  type PackResult,
  type RepackResult,
  type StockMainResult,
} from './pack.ts';
export {
  diffRepack,
  type ByteRange,
  type ChangeKind,
  type RepackDiff,
} from './diff.ts';
export {
  formatDiff,
  formatInspect,
  formatVerdict,
  formatVerify,
} from './format.ts';
export {
  STOCK_CDN_BASE,
  STOCK_RELEASES,
  stockRelease,
  stockReleaseBySha256,
  stockReleaseUrl,
  type StockRelease,
} from './catalog.ts';
export * from './transfer/index.ts';
