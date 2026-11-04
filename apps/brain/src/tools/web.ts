import { isIP } from 'node:net';
import { z } from 'zod';
import { stripHtml } from '../util/text.ts';
import type { ToolDef } from './registry.ts';

const MAX_REDIRECTS = 5;

const v4 = (s: string): number[] | null => {
  const p = s.split('.');
  if (p.length !== 4) return null;
  const n = p.map((x) => (/^\d{1,3}$/.test(x) ? Number(x) : NaN));
  return n.every((x) => x >= 0 && x <= 255) ? n : null;
};

/** Private, loopback, link-local, CGNAT, multicast/reserved IPv4. */
function privateV4([a, b]: number[]): boolean {
  return (
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b! >= 64 && b! <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b! >= 16 && b! <= 31) ||
    (a === 192 && b === 168) ||
    (a === 192 && b === 0) ||
    (a === 198 && (b === 18 || b === 19)) ||
    a! >= 224
  );
}

/** 8 hextets, or null. Accepts an embedded dotted IPv4 tail (::ffff:1.2.3.4). */
function v6(s: string): number[] | null {
  let str = s.toLowerCase().split('%')[0]!;
  const tail = /(\d+\.\d+\.\d+\.\d+)$/.exec(str);
  if (tail) {
    const q = v4(tail[1]!);
    if (!q) return null;
    str =
      str.slice(0, -tail[1]!.length) +
      ((q[0]! << 8) | q[1]!).toString(16) +
      ':' +
      ((q[2]! << 8) | q[3]!).toString(16);
  }
  const halves = str.split('::');
  if (halves.length > 2) return null;
  const parse = (h: string) => (h ? h.split(':') : []);
  const head = parse(halves[0]!);
  const rest = halves.length === 2 ? parse(halves[1]!) : [];
  const fill = 8 - head.length - rest.length;
  if (halves.length === 1 ? fill !== 0 : fill < 0) return null;
  const all = [...head, ...Array<string>(fill).fill('0'), ...rest];
  const n = all.map((x) => (/^[0-9a-f]{1,4}$/.test(x) ? parseInt(x, 16) : NaN));
  return n.length === 8 && n.every((x) => !Number.isNaN(x)) ? n : null;
}

/** True for any address web_fetch must not reach (unparseable addresses count as private). */
export function isPrivateAddress(ip: string): boolean {
  const a = ip.replace(/^\[|\]$/g, '');
  const four = v4(a);
  if (four) return privateV4(four);
  const h = v6(a);
  if (!h) return true;
  const embedded = (hi: number, lo: number) =>
    privateV4([hi >> 8, hi & 255, lo >> 8, lo & 255]);
  const zeros = (n: number) => h.slice(0, n).every((x) => x === 0);
  if (zeros(8)) return true; // ::
  if (zeros(7) && h[7] === 1) return true; // ::1
  if (zeros(5) && h[5] === 0xffff) return embedded(h[6]!, h[7]!); // ::ffff:a.b.c.d
  if (zeros(6)) return embedded(h[6]!, h[7]!); // ::a.b.c.d (IPv4-compatible)
  if (zeros(4) && h[4] === 0xffff && h[5] === 0) return embedded(h[6]!, h[7]!); // ::ffff:0:a.b.c.d (SIIT)
  if (h[0] === 0x64 && h[1] === 0xff9b && h[2] === 1) return true; // 64:ff9b:1::/48 (local NAT64)
  if (h[0] === 0x2001 && h[1] === 0) return true; // Teredo 2001::/32
  if (h[0] === 0x64 && h[1] === 0xff9b && h.slice(2, 6).every((x) => x === 0))
    return embedded(h[6]!, h[7]!); // NAT64
  if (h[0] === 0x2002) return embedded(h[1]!, h[2]!); // 6to4
  const first = h[0]!;
  return (
    (first & 0xfe00) === 0xfc00 || // fc00::/7
    (first & 0xffc0) === 0xfe80 || // fe80::/10
    (first & 0xffc0) === 0xfec0 || // fec0::/10 (site-local)
    (first & 0xff00) === 0xff00 // ff00::/8
  );
}

export type Resolver = (host: string) => Promise<string[]>;

/** null = allowed, otherwise the reason. Literal IPs (any form the URL parser normalises) are checked directly. */
async function blockedReason(u: URL, resolve: Resolver): Promise<string | null> {
  if (!/^https?:$/.test(u.protocol)) return 'Only http(s) URLs are allowed.';
  const host = u.hostname.replace(/^\[|\]$/g, '');
  let addrs: string[];
  if (isIP(host)) addrs = [host];
  else {
    try {
      addrs = await resolve(host);
    } catch {
      return `Cannot resolve ${host}.`;
    }
  }
  if (!addrs.length || addrs.some(isPrivateAddress))
    return 'Local and private addresses are blocked.';
  return null;
}

/** Read at most `maxBytes` of the body (the rest is never downloaded). */
async function readCapped(
  res: Response,
  maxBytes: number,
): Promise<{ text: string; cut: boolean }> {
  if (!res.body) return { text: '', cut: false };
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let text = '';
  let n = 0;
  let cut = false;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    const room = maxBytes - n;
    const chunk = value.byteLength > room ? value.subarray(0, room) : value;
    n += chunk.byteLength;
    text += dec.decode(chunk, { stream: true });
    if (n >= maxBytes) {
      cut = true;
      await reader.cancel().catch(() => {});
      break;
    }
  }
  return { text: text + dec.decode(), cut };
}

const schema = z.object({
  url: z.string().url().describe('http(s) URL'),
  maxChars: z
    .number()
    .int()
    .min(500)
    .max(50_000)
    .optional()
    .describe('Max characters returned (default 12000)'),
});

export const webFetchTool: ToolDef = {
  name: 'web_fetch',
  description:
    'Fetch a web page or API (GET) and return its text (HTML is reduced to plain text). Private/local addresses are blocked.',
  inputSchema: schema,
  kind: 'server',
  status: { de: 'Rufe Webseite ab …', en: 'Fetching a page …' },
  async handler(args: z.infer<typeof schema>, { app, run }) {
    if (!app.settings.bool('web_fetch.enabled'))
      return 'web_fetch is turned off in the settings.';
    const signal = AbortSignal.any([
      AbortSignal.timeout(15_000),
      ...(run.signal ? [run.signal] : []),
    ]);
    let u = new URL(args.url);
    let res: Response | undefined;
    // Redirects are followed by hand so every hop is checked again.
    for (let hop = 0; ; hop++) {
      const why = await blockedReason(u, app.lookup);
      if (why) return why;
      res = await app.fetch(u, {
        signal,
        redirect: 'manual',
        headers: {
          'user-agent': 'LottiBrain/0.1',
          accept: 'text/html,application/json,text/plain,*/*',
        },
      });
      const loc = res.headers.get('location');
      if (res.status < 300 || res.status >= 400 || !loc) break;
      await res.body?.cancel().catch(() => {});
      if (hop >= MAX_REDIRECTS) return `Too many redirects (${MAX_REDIRECTS}).`;
      u = new URL(loc, u);
    }
    const ct = res.headers.get('content-type') ?? '';
    const max = args.maxChars ?? 12_000;
    // Raw HTML is mostly markup: cap the download, not the text (truncated after stripping).
    const read = await readCapped(res, 4_000_000);
    let body = read.text;
    if (/html/i.test(ct)) body = stripHtml(body);
    const cut = read.cut || body.length > max;
    return `HTTP ${res.status} ${ct}\n${body.slice(0, max)}${cut ? `\n[truncated at ${max} characters]` : ''}`;
  },
};
