// The brick guards (docs/wisp/safety.md). Every guard is always evaluated:
// there is deliberately no parameter, option or flag that skips one.

import { hex32 } from './bytes.ts';
import {
  APP_END_CEILING,
  COMPONENT_TYPE_NAMES,
  EVEN_BOOTLOADER_END,
  MAIN_COMPONENT_TYPE,
  MAIN_LOAD_ADDRESS,
  MAIN_PATH,
  MAIN_STORAGE_TYPE,
  MAX_BUNDLE_SIZE,
  MIN_VECTOR_TABLE_SIZE,
  PREAMBLE_DATA_TYPE,
  PREAMBLE_FLAGS,
  PREAMBLE_MAX_SIZE,
  PREAMBLE_SIZE,
  SBL_START,
  SRAM_END,
  SRAM_START,
  STORAGE_TYPE_NAMES,
  UPDATE_FLAG_ADDRESS,
} from './constants.ts';
import { crc32, crc32Bitwise, crc32cMsb, crc32cMsbBitwise } from './crc.ts';
import {
  EvenotaFormatError,
  parseBundle,
  parseMainImage,
  type Bundle,
  type MainImage,
} from './parse.ts';

export type GuardId =
  | 'container'
  | 'bundle-size'
  | 'component-crc'
  | 'main-only'
  | 'main-present'
  | 'main-target'
  | 'preamble-format'
  | 'load-address'
  | 'preamble-size'
  | 'image-size'
  | 'app-end'
  | 'protected-regions'
  | 'sp-vector'
  | 'reset-vector'
  | 'preamble-crc';

/**
 * `integrity`: the bundle is well-formed and its main image is safe to install.
 * `sendable`: additionally, Wisp may send it (main-only, safety.md rule 2).
 */
export type GuardScope = 'integrity' | 'sendable';

export interface GuardSpec {
  id: GuardId;
  scope: GuardScope;
  /** The safety.md hard rule the guard enforces. */
  rule: string;
  description: string;
}

export const GUARDS: readonly GuardSpec[] = [
  {
    id: 'container',
    scope: 'integrity',
    rule: '3',
    description:
      'EVENOTA structure is the stock layout: magic, TOC, trailer, contiguous components closing at EOF, "EVEN" component magic, reserved words',
  },
  {
    id: 'bundle-size',
    scope: 'integrity',
    rule: '1, 3',
    description: `bundle is at most ${MAX_BUNDLE_SIZE} bytes`,
  },
  {
    id: 'component-crc',
    scope: 'integrity',
    rule: '3',
    description:
      'every component: TOC CRC-32C = header CRC-32C = computed CRC-32C (table and bitwise implementations)',
  },
  {
    id: 'main-only',
    scope: 'sendable',
    rule: '2',
    description:
      'exactly one component, and it is type 0 (main); types 1–6 are never sent',
  },
  {
    id: 'main-present',
    scope: 'integrity',
    rule: '2, 3',
    description: 'exactly one type-0 (main) component',
  },
  {
    id: 'main-target',
    scope: 'integrity',
    rule: '1',
    description: `main component goes to the stock staging file "${MAIN_PATH}" (storage type ${MAIN_STORAGE_TYPE}, littlefs)`,
  },
  {
    id: 'preamble-format',
    scope: 'integrity',
    rule: '3',
    description: `preamble flags 0x${PREAMBLE_FLAGS.toString(16)}, data type 0x${PREAMBLE_DATA_TYPE.toString(16)}, reserved words 0`,
  },
  {
    id: 'load-address',
    scope: 'integrity',
    rule: '1, 3',
    description: `preamble load address is ${hex32(MAIN_LOAD_ADDRESS)}`,
  },
  {
    id: 'preamble-size',
    scope: 'integrity',
    rule: '3',
    description: 'preamble size field = payload size',
  },
  {
    id: 'image-size',
    scope: 'integrity',
    rule: '3',
    description: `payload holds the preamble and a full vector table, and fits the 24-bit size field`,
  },
  {
    id: 'app-end',
    scope: 'integrity',
    rule: '3',
    description: `app end (actual and declared) ≤ ${hex32(APP_END_CEILING)}`,
  },
  {
    id: 'protected-regions',
    scope: 'integrity',
    rule: '1',
    description: `installed range stays inside [${hex32(EVEN_BOOTLOADER_END)}, ${hex32(UPDATE_FLAG_ADDRESS)}): never the SBL, the Even bootloader, the update flag or past it`,
  },
  {
    id: 'sp-vector',
    scope: 'integrity',
    rule: '3',
    description: `initial SP in SRAM (${hex32(SRAM_START)}, ${hex32(SRAM_END)}], 8-byte aligned`,
  },
  {
    id: 'reset-vector',
    scope: 'integrity',
    rule: '3',
    description:
      'reset vector is Thumb (odd) and points inside the installed image, past the vector table',
  },
  {
    id: 'preamble-crc',
    scope: 'integrity',
    rule: '3',
    description:
      'preamble zlib CRC-32 over payload[8:] matches (table and bitwise implementations)',
  },
];

export interface GuardResult {
  id: GuardId;
  scope: GuardScope;
  rule: string;
  ok: boolean;
  detail: string;
}

function result(id: GuardId, ok: boolean, detail: string): GuardResult {
  const spec = GUARDS.find((g) => g.id === id)!;
  return { id, scope: spec.scope, rule: spec.rule, ok, detail };
}

const MAIN_IMAGE_GUARDS: readonly GuardId[] = [
  'preamble-format',
  'load-address',
  'preamble-size',
  'image-size',
  'app-end',
  'protected-regions',
  'sp-vector',
  'reset-vector',
  'preamble-crc',
];

/** The guards on a main-app payload (preamble + image), as it would be staged. */
export function checkMainPayload(payload: Uint8Array): GuardResult[] {
  let image: MainImage;
  try {
    image = parseMainImage(payload);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return MAIN_IMAGE_GUARDS.map((id) =>
      result(id, false, `not evaluated: ${message}`),
    );
  }
  const p = image.preamble;
  const out: GuardResult[] = [];

  const formatProblems: string[] = [];
  if (p.flags !== PREAMBLE_FLAGS)
    formatProblems.push(`flags 0x${p.flags.toString(16)}`);
  if (p.dataType !== PREAMBLE_DATA_TYPE)
    formatProblems.push(`data type ${hex32(p.dataType)}`);
  if (p.reserved.some((w) => w !== 0))
    formatProblems.push('reserved words nonzero');
  out.push(
    result(
      'preamble-format',
      formatProblems.length === 0,
      formatProblems.length === 0
        ? 'flags 0x04, type 0xcb'
        : formatProblems.join(', '),
    ),
  );

  out.push(
    result(
      'load-address',
      p.loadAddress === MAIN_LOAD_ADDRESS,
      `load address ${hex32(p.loadAddress)}`,
    ),
  );

  out.push(
    result(
      'preamble-size',
      p.declaredSize === payload.length,
      `declared ${p.declaredSize}, payload ${payload.length}`,
    ),
  );

  const minPayload = PREAMBLE_SIZE + MIN_VECTOR_TABLE_SIZE;
  out.push(
    result(
      'image-size',
      payload.length >= minPayload && payload.length <= PREAMBLE_MAX_SIZE,
      `payload ${payload.length} bytes (allowed ${minPayload}..${PREAMBLE_MAX_SIZE})`,
    ),
  );

  const end = Math.max(image.appEnd, image.declaredEnd);
  out.push(
    result(
      'app-end',
      end <= APP_END_CEILING,
      `app end ${hex32(image.appEnd)}, declared end ${hex32(image.declaredEnd)}, ceiling ${hex32(APP_END_CEILING)}`,
    ),
  );

  const start = p.loadAddress;
  const insideAllowed =
    start >= EVEN_BOOTLOADER_END && end <= UPDATE_FLAG_ADDRESS && start < end;
  const touched: string[] = [];
  if (start < EVEN_BOOTLOADER_END && end > SBL_START)
    touched.push('SBL / Even bootloader');
  if (end > UPDATE_FLAG_ADDRESS) touched.push('update flag / NV area');
  out.push(
    result(
      'protected-regions',
      insideAllowed,
      `installs [${hex32(start)}, ${hex32(end)})${touched.length ? `, overlaps ${touched.join(' and ')}` : ''}`,
    ),
  );

  const sp = image.initialSp;
  out.push(
    result(
      'sp-vector',
      sp > SRAM_START && sp <= SRAM_END && sp % 8 === 0,
      `initial SP ${hex32(sp)}`,
    ),
  );

  const reset = image.resetVector;
  const handler = (reset & ~1) >>> 0;
  const firstCode = MAIN_LOAD_ADDRESS + MIN_VECTOR_TABLE_SIZE;
  out.push(
    result(
      'reset-vector',
      (reset & 1) === 1 &&
        p.loadAddress === MAIN_LOAD_ADDRESS &&
        handler >= firstCode &&
        handler < image.appEnd,
      `reset ${hex32(reset)} (${reset & 1 ? 'Thumb' : 'not Thumb'}), image [${hex32(MAIN_LOAD_ADDRESS)}, ${hex32(image.appEnd)})`,
    ),
  );

  const covered = payload.subarray(8);
  const table = crc32(covered);
  const bitwise = crc32Bitwise(covered);
  out.push(
    result(
      'preamble-crc',
      p.crc32 === table && p.crc32 === bitwise,
      `stored ${hex32(p.crc32)}, table ${hex32(table)}, bitwise ${hex32(bitwise)}`,
    ),
  );
  return out;
}

export interface ComponentReport {
  index: number;
  entryId: number;
  type: number;
  typeName: string;
  storageType: number;
  storageName: string;
  path: string;
  offset: number;
  payloadSize: number;
  tocCrc32c: string;
  headerCrc32c: string;
  computedCrc32c: string;
  crcOk: boolean;
}

export interface MainReport {
  flags: number;
  declaredSize: number;
  payloadSize: number;
  crc32: string;
  computedCrc32: string;
  dataType: string;
  loadAddress: string;
  initialSp: string;
  resetVector: string;
  installedSize: number;
  appEnd: string;
  declaredEnd: string;
  headroomBelowCeiling: number;
}

export interface VerifyReport {
  reportVersion: 1;
  /** All integrity guards pass: well-formed bundle with a safe main image. */
  ok: boolean;
  /** `ok` and every sendable guard passes: Wisp may send this bundle. */
  sendable: boolean;
  bundle: {
    size: number;
    componentCount: number;
    version: string;
    buildDate: string;
    buildTime: string;
  } | null;
  components: ComponentReport[];
  main: MainReport | null;
  guards: GuardResult[];
  failed: GuardId[];
}

function finish(
  guards: GuardResult[],
  bundle: VerifyReport['bundle'],
  components: ComponentReport[],
  main: MainReport | null,
): VerifyReport {
  const failed = guards.filter((g) => !g.ok).map((g) => g.id);
  const ok = guards.every((g) => g.scope !== 'integrity' || g.ok);
  // Every guard id must be present: a missing guard is a failure, not a pass.
  const complete = GUARDS.every((spec) => guards.some((g) => g.id === spec.id));
  return {
    reportVersion: 1,
    ok: ok && complete,
    sendable: ok && complete && guards.every((g) => g.ok),
    bundle,
    components,
    main,
    guards,
    failed,
  };
}

/** Parses `bytes` from scratch and evaluates every guard. Never throws on bad input. */
export function verifyBundle(bytes: Uint8Array): VerifyReport {
  const guards: GuardResult[] = [];
  guards.push(
    result(
      'bundle-size',
      bytes.length <= MAX_BUNDLE_SIZE,
      `${bytes.length} bytes (max ${MAX_BUNDLE_SIZE})`,
    ),
  );
  let bundle: Bundle;
  try {
    bundle = parseBundle(bytes);
  } catch (error) {
    const message =
      error instanceof EvenotaFormatError || error instanceof RangeError
        ? error.message
        : String(error);
    guards.push(result('container', false, message));
    for (const spec of GUARDS) {
      if (!guards.some((g) => g.id === spec.id))
        guards.push(result(spec.id, false, 'not evaluated: unreadable bundle'));
    }
    return finish(guards, null, [], null);
  }

  guards.push(
    result(
      'container',
      bundle.issues.length === 0,
      bundle.issues.length === 0
        ? `${bundle.componentCount} component(s), stock layout`
        : bundle.issues.join('; '),
    ),
  );

  const components: ComponentReport[] = bundle.components.map((c) => {
    const table = crc32cMsb(c.payload);
    const bitwise = crc32cMsbBitwise(c.payload);
    const crcOk =
      table === bitwise && c.toc.crc32c === table && c.header.crc32c === table;
    return {
      index: c.index,
      entryId: c.toc.entryId,
      type: c.header.type,
      typeName: COMPONENT_TYPE_NAMES[c.header.type] ?? 'unknown',
      storageType: c.header.storageType,
      storageName: STORAGE_TYPE_NAMES[c.header.storageType] ?? 'unknown',
      path: c.header.path.text,
      offset: c.toc.offset,
      payloadSize: c.payload.length,
      tocCrc32c: hex32(c.toc.crc32c),
      headerCrc32c: hex32(c.header.crc32c),
      computedCrc32c:
        table === bitwise
          ? hex32(table)
          : `${hex32(table)} (table) != ${hex32(bitwise)} (bitwise)`,
      crcOk,
    };
  });
  const badCrc = components.filter((c) => !c.crcOk);
  guards.push(
    result(
      'component-crc',
      badCrc.length === 0,
      badCrc.length === 0
        ? `${components.length} component CRC-32C(s) match`
        : badCrc
            .map(
              (c) =>
                `${c.path || `component ${c.index + 1}`}: TOC ${c.tocCrc32c}, header ${c.headerCrc32c}, computed ${c.computedCrc32c}`,
            )
            .join('; '),
    ),
  );

  const mains = bundle.components.filter(
    (c) => c.header.type === MAIN_COMPONENT_TYPE,
  );
  const others = bundle.components.filter(
    (c) => c.header.type !== MAIN_COMPONENT_TYPE,
  );
  guards.push(
    result(
      'main-only',
      bundle.componentCount === 1 && mains.length === 1,
      others.length === 0
        ? `${bundle.componentCount} component(s), all main`
        : `also carries type(s) ${others.map((c) => `${c.header.type} (${COMPONENT_TYPE_NAMES[c.header.type] ?? 'unknown'})`).join(', ')}`,
    ),
  );
  guards.push(
    result(
      'main-present',
      mains.length === 1,
      `${mains.length} main component(s)`,
    ),
  );

  let main: MainReport | null = null;
  if (mains.length === 1) {
    const m = mains[0]!;
    guards.push(
      result(
        'main-target',
        m.header.path.text === MAIN_PATH &&
          m.header.storageType === MAIN_STORAGE_TYPE,
        `path "${m.header.path.text}", storage type ${m.header.storageType}`,
      ),
    );
    guards.push(...checkMainPayload(m.payload));
    try {
      const image = parseMainImage(m.payload);
      main = {
        flags: image.preamble.flags,
        declaredSize: image.preamble.declaredSize,
        payloadSize: m.payload.length,
        crc32: hex32(image.preamble.crc32),
        computedCrc32: hex32(crc32(m.payload.subarray(8))),
        dataType: hex32(image.preamble.dataType),
        loadAddress: hex32(image.preamble.loadAddress),
        initialSp: hex32(image.initialSp),
        resetVector: hex32(image.resetVector),
        installedSize: image.installedSize,
        appEnd: hex32(image.appEnd),
        declaredEnd: hex32(image.declaredEnd),
        headroomBelowCeiling:
          APP_END_CEILING - Math.max(image.appEnd, image.declaredEnd),
      };
    } catch {
      main = null;
    }
  } else {
    guards.push(
      result('main-target', false, 'not evaluated: no single main component'),
    );
    for (const id of MAIN_IMAGE_GUARDS)
      guards.push(result(id, false, 'not evaluated: no single main component'));
  }

  return finish(
    guards,
    {
      size: bytes.length,
      componentCount: bundle.componentCount,
      version: bundle.version.text,
      buildDate: bundle.buildDate.text,
      buildTime: bundle.buildTime.text,
    },
    components,
    main,
  );
}

export class GuardError extends Error {
  override name = 'GuardError';
  constructor(
    message: string,
    readonly failed: GuardResult[],
  ) {
    super(
      `${message}: ${failed.map((g) => `${g.id} (${g.detail})`).join('; ')}`,
    );
  }
}

/** Throws unless every guard, including main-only, passes. */
export function assertSendable(bytes: Uint8Array): VerifyReport {
  const report = verifyBundle(bytes);
  if (!report.sendable) {
    throw new GuardError(
      'bundle is not sendable',
      report.guards.filter((g) => !g.ok),
    );
  }
  return report;
}
