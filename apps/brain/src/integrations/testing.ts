import { jsonResponse, makeApp } from '../testing/helpers.ts';
import { registerIntegrations } from './register.ts';

export interface Seen {
  method: string;
  url: string;
  headers: Record<string, string>;
  body: string;
}

/** Tiny mock for `fetch`: first matching route (method + url substring/regex) answers. */
export function mockFetch(
  routes: {
    m?: string;
    u: string | RegExp;
    res: (req: Seen) => Response | Promise<Response> | unknown;
  }[],
): { fetch: typeof fetch; seen: Seen[] } {
  const seen: Seen[] = [];
  const f = (async (input: any, init: any = {}) => {
    const req: Seen = {
      method: init.method ?? 'GET',
      url: String(input instanceof URL ? input.href : (input?.url ?? input)),
      headers: Object.fromEntries(
        Object.entries(init.headers ?? {}).map(([k, v]) => [
          k.toLowerCase(),
          String(v),
        ]),
      ),
      body: init.body ? String(init.body) : '',
    };
    seen.push(req);
    const r = routes.find(
      (x) =>
        (!x.m || x.m === req.method) &&
        (typeof x.u === 'string' ? req.url.includes(x.u) : x.u.test(req.url)),
    );
    if (!r)
      return new Response('no route ' + req.method + ' ' + req.url, {
        status: 404,
      });
    const v = await r.res(req);
    return v instanceof Response ? v : jsonResponse(v);
  }) as typeof fetch;
  return { fetch: f, seen };
}

export function googleApp(extra: Parameters<typeof mockFetch>[0] = []) {
  let n = 0;
  const m = mockFetch([
    ...extra,
    {
      m: 'POST',
      u: 'oauth2.googleapis.com/token',
      res: (r) => {
        const f = new URLSearchParams(r.body);
        n++;
        if (f.get('grant_type') === 'authorization_code')
          return f.get('code') === 'good'
            ? { access_token: 'at1', refresh_token: 'rt1', expires_in: 3600 }
            : new Response(
                '{"error":"invalid_grant","error_description":"Bad code"}',
                { status: 400 },
              );
        return f.get('refresh_token') === 'rt1'
          ? { access_token: 'at' + (n + 1), expires_in: 3600 }
          : new Response('{"error":"invalid_grant"}', { status: 400 });
      },
    },
    {
      u: 'openidconnect.googleapis.com',
      res: () => ({ email: 'jan@gmail.com' }),
    },
  ]);
  const t = makeApp({ fetch: m.fetch });
  registerIntegrations(t.app);
  return { t, m };
}

export async function connectGoogle(
  t: ReturnType<typeof makeApp>,
): Promise<string> {
  await t.app.ops.invoke(
    'accounts.set_google_client',
    { clientId: 'cid', clientSecret: 'csec', redirectUri: 'lotti://oauth' },
    'app',
  );
  const u = (await t.app.ops.invoke(
    'accounts.google_auth_url',
    {},
    'app',
  )) as any;
  const x = (await t.app.ops.invoke(
    'accounts.google_exchange',
    { code: 'good', state: u.result.state },
    'app',
  )) as any;
  return x.result.accountId;
}
