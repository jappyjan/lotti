import { z } from 'zod';
import { stripHtml } from '../util/text.ts';
import type { ToolDef } from './registry.ts';

const BLOCKED =
  /^(localhost|127\.|0\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$|metadata\.google)/i;

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
    const u = new URL(args.url);
    if (!/^https?:$/.test(u.protocol)) return 'Only http(s) URLs are allowed.';
    if (BLOCKED.test(u.hostname))
      return 'Local and private addresses are blocked.';
    const signals = [
      AbortSignal.timeout(15_000),
      ...(run.signal ? [run.signal] : []),
    ];
    const res = await app.fetch(u, {
      signal: AbortSignal.any(signals),
      headers: {
        'user-agent': 'LottiBrain/0.1',
        accept: 'text/html,application/json,text/plain,*/*',
      },
    });
    const ct = res.headers.get('content-type') ?? '';
    let body = await res.text();
    if (/html/i.test(ct)) body = stripHtml(body);
    const max = args.maxChars ?? 12_000;
    const cut = body.length > max;
    return `HTTP ${res.status} ${ct}\n${body.slice(0, max)}${cut ? `\n[truncated at ${max} characters]` : ''}`;
  },
};
