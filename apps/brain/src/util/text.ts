export function clip(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max - 1) + '…';
}

/** Turn free text into a safe FTS5 query (prefix-OR of words). Returns null if no words. */
export function ftsQuery(text: string): string | null {
  const words = text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((w) => w.length >= 2)
    .slice(0, 12);
  if (!words.length) return null;
  return words.map((w) => `"${w}"*`).join(' OR ');
}

/** Find a JSON object/array inside text (fences or prose). */
export function extractJson(text: string): unknown | undefined {
  const t = text.trim();
  const fence = /```(?:json)?\s*([\s\S]*?)```/i.exec(t);
  const candidates = [t, fence?.[1]?.trim()];
  const first = t.search(/[{[]/);
  if (first >= 0) candidates.push(t.slice(first));
  const lastObj = Math.max(t.lastIndexOf('}'), t.lastIndexOf(']'));
  if (first >= 0 && lastObj > first)
    candidates.push(t.slice(first, lastObj + 1));
  for (const c of candidates) {
    if (!c) continue;
    try {
      return JSON.parse(c);
    } catch {
      /* next */
    }
  }
  return undefined;
}

export function stripHtml(html: string): string {
  return html
    .replace(/<(script|style|noscript)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<br\s*\/?>|<\/(p|div|li|h\d|tr)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, ' ')
    .replace(/\n\s*\n+/g, '\n')
    .trim();
}
