import { z } from 'zod';
import type { ToolDef } from '../../tools/registry.ts';

export const SEARCH_SECRET = 'search.brave.api_key';

const schema = z.object({
  query: z.string().min(1),
  count: z.number().int().min(1).max(10).optional(),
  freshness: z
    .enum(['day', 'week', 'month', 'year'])
    .optional()
    .describe('Only results from the last day/week/month/year'),
});

/** Brave Search API when a key exists (secret `search.brave.api_key`); otherwise tells the model to use curl. */
export const webSearchTool: ToolDef = {
  name: 'web_search',
  description:
    'Search the web (title, URL, snippet per result). Use web_fetch to read a result.',
  inputSchema: schema,
  kind: 'server',
  status: { de: 'Suche im Web …', en: 'Searching the web …' },
  async handler(a: z.infer<typeof schema>, { app, run }) {
    const key = app.secrets.get(SEARCH_SECRET);
    if (!key)
      return 'No search API key is configured. Use the shell tool with curl (e.g. curl -s "https://duckduckgo.com/html/?q=..." | head) or web_fetch on a known URL instead. The user can add a Brave Search key in the app (secret search.brave.api_key).';
    const q = new URLSearchParams({ q: a.query, count: String(a.count ?? 5) });
    if (a.freshness)
      q.set(
        'freshness',
        { day: 'pd', week: 'pw', month: 'pm', year: 'py' }[a.freshness],
      );
    const res = await app.fetch(
      `https://api.search.brave.com/res/v1/web/search?${q}`,
      {
        headers: { accept: 'application/json', 'x-subscription-token': key },
        signal: AbortSignal.any([
          AbortSignal.timeout(15_000),
          ...(run.signal ? [run.signal] : []),
        ]),
      },
    );
    if (!res.ok) throw new Error(`Search API answered HTTP ${res.status}`);
    const j: any = await res.json();
    const r = (j.web?.results ?? []) as {
      title: string;
      url: string;
      description?: string;
    }[];
    return r.length
      ? r
          .map(
            (x) =>
              `- ${x.title}\n  ${x.url}\n  ${(x.description ?? '').replace(/<[^>]+>/g, '').slice(0, 240)}`,
          )
          .join('\n')
      : 'No results.';
  },
};
