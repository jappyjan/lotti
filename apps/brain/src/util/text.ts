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

const NAMED: Record<string, string> = {
  nbsp: ' ', amp: '&', lt: '<', gt: '>', quot: '"', apos: "'",
  ndash: '–', mdash: '—', hellip: '…', bull: '•', middot: '·',
  lsquo: '‘', rsquo: '’', sbquo: '‚', ldquo: '“', rdquo: '”', bdquo: '„',
  laquo: '«', raquo: '»', euro: '€', pound: '£', copy: '©', reg: '®', trade: '™',
  auml: 'ä', ouml: 'ö', uuml: 'ü', Auml: 'Ä', Ouml: 'Ö', Uuml: 'Ü', szlig: 'ß',
  eacute: 'é', egrave: 'è', agrave: 'à', aacute: 'á', ccedil: 'ç',
};

/** `&amp;`, `&#8217;`, `&#x200C;` … → characters. Unknown named entities are dropped. */
export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z][a-z0-9]*);/gi, (_, e: string) => {
    if (e[0] === '#') {
      const n = e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : Number(e.slice(1));
      return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '';
    }
    return NAMED[e] ?? NAMED[e.toLowerCase()] ?? '';
  });
}

/** Zero-width and other invisible characters that newsletters pad their preview text with. */
const INVISIBLE =
  /[­͏؜ᅟᅠ឴឵᠎​-‏‪-‮⁠-⁤⁪-⁯ㅤ﻿ﾠ]/g;

/** Invisible characters out, spaces collapsed, at most one blank line in a row. */
export function tidyText(s: string): string {
  return s
    .replace(INVISIBLE, '')
    .replace(/\r\n?/g, '\n')
    .replace(/[ \t ]+/g, ' ')
    .replace(/ *\n */g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** HTML → plain text. Copes with cut-off HTML (an unclosed style block or tag at the end is dropped). */
export function stripHtml(html: string): string {
  return tidyText(
    decodeEntities(
      html
        .replace(/<!--[\s\S]*?(?:-->|$)/g, ' ')
        .replace(/<head[\s>][\s\S]*?(?:<\/head\s*>|$)/gi, ' ')
        .replace(
          /<(script|style|noscript|title|template|svg)\b[\s\S]*?(?:<\/\1\s*>|$)/gi,
          ' ',
        )
        .replace(/<br\s*\/?>|<\/(p|div|li|h\d|tr|table|blockquote)\s*>/gi, '\n')
        .replace(/<[a-z!/?][^>]*(?:>|$)/gi, ' '),
    ),
  );
}

/** Does this "plain text" actually hold HTML markup? (Some senders put HTML in the text part.) */
export function looksLikeHtml(s: string): boolean {
  if (/<!doctype html|<html[\s>]/i.test(s)) return true;
  const tags = s.match(
    /<\/?(?:body|div|table|tr|td|span|p|br|a|img|style|meta|font|center|b|strong)\b[^>]*>/gi,
  );
  return (tags?.length ?? 0) >= 3;
}

/** The readable text of a mail from its text and HTML parts. */
export function mailText(text?: string | null, html?: string | null): string {
  const t = (text ?? '').trim();
  if (t && !looksLikeHtml(t)) return tidyText(decodeEntities(t));
  return stripHtml(html || t);
}

/** Mail text for the AI and the inbox: no quoted replies, no long (tracking) links, no image placeholders. */
export function mailGist(text: string, max: number): string {
  return clip(
    tidyText(
      text
        .split('\n')
        .filter((l) => !/^\s*>/.test(l))
        .join('\n')
        .replace(/<?https?:\/\/\S{30,}>?/g, '')
        .replace(/\[(?:image|bild)[^\]]*\]/gi, ''),
    ),
    max,
  );
}
