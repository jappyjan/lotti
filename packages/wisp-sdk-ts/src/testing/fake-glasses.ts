import { Cap } from '../protocol/constants.ts';
import { WispLink, type Incoming, type LinkOptions } from '../link/link.ts';
import type { Transport } from '../link/transport.ts';
import {
  Display,
  ErrorCode,
  Resource,
  Service,
  Session,
  System,
  findMessage,
  payloadStruct,
} from '../protocol/messages.ts';
import { resourceHash } from '../image/hash.ts';
import { bytesEqual, concatBytes } from '../protocol/bytes.ts';
import { PayloadError } from '../protocol/struct.ts';

export interface Received {
  svc: number;
  op: number;
  name: string;
  fields: Record<string, unknown>;
}

/**
 * A scripted glasses side for tests: answers HELLO, keeps resources, records
 * every request it gets, and answers every request with `req ≠ 0` exactly
 * once (malformed payloads with error 2). Not a simulator.
 */
export class FakeGlasses {
  readonly link: WispLink;
  readonly received: Received[] = [];
  readonly resources = new Map<
    number,
    { hash: Uint8Array; data: Uint8Array }
  >();
  private uploads = new Map<
    number,
    { hash: Uint8Array; parts: Uint8Array[] }
  >();
  caps =
    (1 << Cap.display) |
    (1 << Cap.rle4) |
    (1 << Cap.lz4) |
    (1 << Cap.deltaFrames);
  sessionTimeoutMs = 10_000;
  maxFrame = 4096;
  frameCount = 0;
  /** Hook to answer or drop a request yourself; return true when handled. */
  override?: (m: Incoming) => boolean;

  constructor(transport: Transport, opts: LinkOptions = {}) {
    this.link = new WispLink(transport, { route: 1 << 2, ...opts });
    this.link.events.on('request', (m) => void this.handle(m));
  }

  named(name: string): Received[] {
    return this.received.filter((r) => r.name === name);
  }

  private async handle(m: Incoming) {
    const def = findMessage(m.svc, m.op);
    let fields: Record<string, unknown> = {};
    try {
      if (def) fields = payloadStruct(def, m.mflags)?.decode(m.payload) ?? {};
    } catch (err) {
      if (!(err instanceof PayloadError)) throw err;
      return this.link.respondError(m, ErrorCode.badPayload, err.message);
    }
    this.received.push({
      svc: m.svc,
      op: m.op,
      name: def?.name ?? '?',
      fields,
    });
    if (this.override?.(m)) return;
    const l = this.link;
    if (!def) return l.respondError(m, ErrorCode.unsupportedOp);
    if (m.svc === Service.session && m.op === Session.hello.op) {
      const f = Session.hello.request!.decode(m.payload);
      l.setPeerLimits({ maxFrame: f.maxFrame, rxWindow: f.rxWindow });
      return l.respond(
        m,
        Session.hello.response!.encode({
          protoMajor: 0,
          protoMinor: 2,
          maxFrame: this.maxFrame,
          rxWindow: l.rxWindow,
          fwName: 'fake',
          fwVersion: '0.0.0',
          lens: 1,
          caps: this.caps,
          canvasW: 640,
          canvasH: 480,
          bpp: 4,
          maxLayers: 8,
          resBytes: 1 << 20,
          persistBytes: 1 << 20,
          sessionTimeoutMs: this.sessionTimeoutMs,
        }),
      );
    }
    if (m.svc === Service.session && m.op === Session.timeSync.op) {
      const f = Session.timeSync.request!.decode(m.payload);
      return l.respond(
        m,
        Session.timeSync.response!.encode({
          phoneMs: f.phoneMs,
          glassUs: Date.now() * 1000 + 5e9,
        }),
      );
    }
    if (m.svc === Service.display && m.op === Display.commit.op)
      return l.respond(
        m,
        Display.commit.response!.encode({
          frame: ++this.frameCount,
          glassUs: 1,
        }),
      );
    if (m.svc === Service.system && m.op === System.info.op)
      return l.respond(
        m,
        System.info.response!.encode({ hwRev: 'fake', serial: 'F00', lens: 1 }),
      );
    if (m.svc === Service.resource) {
      if (m.op === Resource.putBegin.op) {
        const f = Resource.putBegin.request!.decode(m.payload);
        const have = this.resources.get(f.res);
        if (have && bytesEqual(have.hash, f.hash))
          return l.respond(
            m,
            Resource.putBegin.response!.encode({ status: 1 }),
          );
        this.uploads.set(f.res, { hash: f.hash, parts: [] });
        return l.respond(m, Resource.putBegin.response!.encode({ status: 0 }));
      }
      if (m.op === Resource.putData.op) {
        const f = Resource.putData.request!.decode(m.payload);
        this.uploads.get(f.res)?.parts.push(f.data);
        return l.respond(m);
      }
      if (m.op === Resource.putEnd.op) {
        const f = Resource.putEnd.request!.decode(m.payload);
        const up = this.uploads.get(f.res);
        if (!up) return l.respondError(m, ErrorCode.noSuchId);
        const data = concatBytes(up.parts);
        if (!bytesEqual(await resourceHash(data), up.hash))
          return l.respondError(m, ErrorCode.hashMismatch);
        this.resources.set(f.res, { hash: up.hash, data });
        return l.respond(m);
      }
    }
    l.respond(m);
  }
}
