import { createPrivateKey, createSign } from 'node:crypto';
import { connect } from 'node:http2';
import type { App } from '../../app.ts';
import type { InboxItem } from '../../inbox.ts';
import type { DeviceInfo, PushNotifier } from '../index.ts';

export const APNS_SECRETS = {
  key: 'push.apns.key',
  keyId: 'push.apns.key_id',
  teamId: 'push.apns.team_id',
  topic: 'push.apns.topic',
};

export interface ApnsConfig {
  key: string;
  keyId: string;
  teamId: string;
  topic: string;
  production: boolean;
}

const b64u = (b: Buffer | string) => Buffer.from(b).toString('base64url');

/** ES256 provider token (JWT) for APNs token-based auth. `iat` in seconds. */
export function apnsJwt(
  c: Pick<ApnsConfig, 'key' | 'keyId' | 'teamId'>,
  nowMs: number,
): string {
  const head = b64u(JSON.stringify({ alg: 'ES256', kid: c.keyId }));
  const body = b64u(
    JSON.stringify({ iss: c.teamId, iat: Math.floor(nowMs / 1000) }),
  );
  const sig = createSign('SHA256')
    .update(`${head}.${body}`)
    .sign({ key: createPrivateKey(c.key), dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64u(sig)}`;
}

/** Alert + content-available so iOS also wakes the app in the background to sync the inbox. */
export function apnsPayload(
  item: Pick<InboxItem, 'id' | 'kind' | 'title' | 'summary'>,
) {
  return {
    aps: {
      alert: { title: item.title, body: item.summary || item.title },
      sound: 'default',
      'content-available': 1,
    },
    itemId: item.id,
    kind: item.kind,
  };
}

export interface ApnsResponse {
  status: number;
  body: string;
}
/** Transport seam (HTTP/2); tests replace it. */
export type ApnsTransport = (
  host: string,
  path: string,
  headers: Record<string, string>,
  body: string,
) => Promise<ApnsResponse>;

export const http2Transport: ApnsTransport = (host, path, headers, body) =>
  new Promise((resolve, reject) => {
    const session = connect(`https://${host}`);
    const done = (f: () => void) => {
      session.close();
      f();
    };
    session.on('error', (e) => done(() => reject(e)));
    const req = session.request({
      ':method': 'POST',
      ':path': path,
      ...headers,
    });
    let status = 0;
    let data = '';
    req.setEncoding('utf8');
    req.on('response', (h) => (status = Number(h[':status'])));
    req.on('data', (d) => (data += d));
    req.on('end', () => done(() => resolve({ status, body: data })));
    req.on('error', (e) => done(() => reject(e)));
    req.setTimeout(15_000, () => req.close());
    req.end(body);
  });

/** APNs sender. OFF until configured (app ops `push.configure`, or APNS_* env). */
export class ApnsPush implements PushNotifier {
  private jwt?: { token: string; at: number; keyId: string };
  constructor(
    private app: App,
    private transport: ApnsTransport = http2Transport,
  ) {}

  config(): ApnsConfig | undefined {
    const s = this.app.secrets;
    const e = this.app.config.apns;
    const key = s.get(APNS_SECRETS.key) ?? e?.key;
    const keyId = s.get(APNS_SECRETS.keyId) ?? e?.keyId;
    const teamId = s.get(APNS_SECRETS.teamId) ?? e?.teamId;
    const topic = s.get(APNS_SECRETS.topic) ?? e?.topic;
    if (!key || !keyId || !teamId || !topic) return undefined;
    return {
      key: key.includes('BEGIN') ? key : key.replace(/\\n/g, '\n'),
      keyId,
      teamId,
      topic,
      // Keys stored via the app follow the setting; keys from the environment follow APNS_PRODUCTION.
      production: s.has(APNS_SECRETS.key)
        ? this.app.settings.bool('push.apns.production')
        : (e?.production ?? true),
    };
  }
  configured(): boolean {
    return !!this.config();
  }

  private token(c: ApnsConfig): string {
    const now = this.app.clock.now();
    // Apple wants a refresh between 20 and 60 minutes.
    if (
      !this.jwt ||
      now - this.jwt.at > 40 * 60_000 ||
      this.jwt.keyId !== c.keyId
    )
      this.jwt = { token: apnsJwt(c, now), at: now, keyId: c.keyId };
    return this.jwt.token;
  }

  /** Send one push. Returns APNs' verdict; a dead token is removed from the device. */
  async send(
    device: DeviceInfo,
    payload: object,
  ): Promise<{ ok: boolean; status: number; reason?: string }> {
    const c = this.config();
    if (!c) return { ok: false, status: 0, reason: 'APNs is not configured' };
    if (!device.apnsToken)
      return { ok: false, status: 0, reason: 'device has no APNs token' };
    const r = await this.transport(
      c.production ? 'api.push.apple.com' : 'api.sandbox.push.apple.com',
      `/3/device/${device.apnsToken}`,
      {
        authorization: `bearer ${this.token(c)}`,
        'apns-topic': c.topic,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'content-type': 'application/json',
      },
      JSON.stringify(payload),
    );
    if (r.status === 200) return { ok: true, status: 200 };
    let reason = r.body;
    try {
      reason = JSON.parse(r.body).reason ?? r.body;
    } catch {
      /* raw */
    }
    if (
      r.status === 410 ||
      reason === 'BadDeviceToken' ||
      reason === 'Unregistered'
    )
      this.app.db.run(
        'UPDATE devices SET apns_token=NULL WHERE id=?',
        device.id,
      );
    return { ok: false, status: r.status, reason };
  }

  async notifyOffline(device: DeviceInfo, item: InboxItem): Promise<void> {
    if (!device.apnsToken || !this.configured()) return;
    const r = await this.send(device, apnsPayload(item));
    if (!r.ok)
      this.app.log.warn(
        `APNs push to ${device.name} failed: ${r.status} ${r.reason}`,
      );
  }
}
