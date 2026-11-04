import type { CalendarEvent } from '../index.ts';
import { buildEvent, parseEvents } from './ics.ts';

export interface DavAuth {
  /** Base URL of the CalDAV service (iCloud: https://caldav.icloud.com). */
  url: string;
  username: string;
  password: string;
}
export interface DavCalendar {
  id: string; // absolute URL
  name: string;
}

const decode = (s: string) =>
  s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');

/** Contents of every element whose local name is `tag` (namespace prefixes ignored). */
function elements(xml: string, tag: string): string[] {
  const re = new RegExp(
    `<(?:[\\w-]+:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[\\w-]+:)?${tag}>`,
    'gi',
  );
  return [...xml.matchAll(re)].map((m) => m[1]!);
}
const first = (xml: string, tag: string) => elements(xml, tag)[0];

/** Hand-rolled CalDAV over fetch (PROPFIND / REPORT / PUT) with HTTP basic auth. */
export class CalDav {
  constructor(
    private auth: DavAuth,
    private fetchFn: typeof fetch,
  ) {}

  private async dav(
    method: string,
    url: string,
    body: string,
    headers: Record<string, string> = {},
  ): Promise<{ status: number; text: string }> {
    const res = await this.fetchFn(url, {
      method,
      headers: {
        authorization:
          'Basic ' +
          Buffer.from(`${this.auth.username}:${this.auth.password}`).toString(
            'base64',
          ),
        'content-type': 'application/xml; charset=utf-8',
        ...headers,
      },
      body,
      redirect: 'follow',
      signal: AbortSignal.timeout(20_000),
    });
    const text = await res.text();
    if (res.status === 401 || res.status === 403)
      throw new Error(
        'CalDAV login failed: check the username and (app-specific) password.',
      );
    if (res.status >= 400)
      throw new Error(`CalDAV ${method} answered HTTP ${res.status}`);
    return { status: res.status, text };
  }

  private abs(href: string, base: string): string {
    return new URL(decode(href).trim(), base).toString();
  }

  async listCalendars(): Promise<DavCalendar[]> {
    const base = this.auth.url;
    const principalXml = (
      await this.dav(
        'PROPFIND',
        base,
        '<d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>',
        { depth: '0' },
      )
    ).text;
    const principalHref = first(
      first(principalXml, 'current-user-principal') ?? '',
      'href',
    );
    if (!principalHref)
      throw new Error('CalDAV: server did not return a user principal.');
    const principal = this.abs(principalHref, base);
    const homeXml = (
      await this.dav(
        'PROPFIND',
        principal,
        '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>',
        { depth: '0' },
      )
    ).text;
    const homeHref = first(first(homeXml, 'calendar-home-set') ?? '', 'href');
    if (!homeHref)
      throw new Error('CalDAV: server did not return a calendar home.');
    const home = this.abs(homeHref, principal);
    const listXml = (
      await this.dav(
        'PROPFIND',
        home,
        '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:displayname/><d:resourcetype/><c:supported-calendar-component-set/></d:prop></d:propfind>',
        { depth: '1' },
      )
    ).text;
    const out: DavCalendar[] = [];
    for (const r of elements(listXml, 'response')) {
      const href = first(r, 'href');
      if (
        !href ||
        !/<(?:[\w-]+:)?calendar\s*\/?>/i.test(first(r, 'resourcetype') ?? '')
      )
        continue;
      const comps = first(r, 'supported-calendar-component-set');
      if (comps && !/name="VEVENT"/i.test(comps)) continue;
      out.push({
        id: this.abs(href, home),
        name: decode(first(r, 'displayname') ?? '').trim() || 'Calendar',
      });
    }
    return out;
  }

  async events(
    cal: DavCalendar,
    from: number,
    to: number,
  ): Promise<CalendarEvent[]> {
    const t = (ms: number) =>
      new Date(ms).toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
    const body =
      `<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-data>` +
      `<c:expand start="${t(from)}" end="${t(to)}"/></c:calendar-data></d:prop>` +
      `<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">` +
      `<c:time-range start="${t(from)}" end="${t(to)}"/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>`;
    const xml = (await this.dav('REPORT', cal.id, body, { depth: '1' })).text;
    const out: CalendarEvent[] = [];
    for (const data of elements(xml, 'calendar-data'))
      out.push(...parseEvents(decode(data), cal.name));
    return out.filter((e) => e.end > from && e.start < to);
  }

  /**
   * Deletes one event by UID. A repeating event (RRULE / RECURRENCE-ID / several VEVENTs) is refused:
   * the resource is the whole series, and deleting it would wipe all of it.
   */
  async delete(cal: DavCalendar, uid: string): Promise<void> {
    const body =
      `<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>` +
      `<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:prop-filter name="UID">` +
      `<c:text-match collation="i;octet">${uid.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</c:text-match>` +
      `</c:prop-filter></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>`;
    const xml = (await this.dav('REPORT', cal.id, body, { depth: '1' })).text;
    // text-match is a substring match: keep only the resource whose UID is exactly this one.
    const hasUid = (r: string) =>
      decode(first(r, 'calendar-data') ?? '')
        .replace(/\r?\n[ \t]/g, '')
        .split(/\r?\n/)
        .some(
          (l) =>
            /^UID(;[^:]*)?:/i.test(l) &&
            l.replace(/^[^:]*:/, '').trim() === uid,
        );
    const hits = elements(xml, 'response').filter(
      (r) => first(r, 'href') && hasUid(r),
    );
    if (hits.length !== 1)
      throw new Error(
        hits.length ? 'More than one event matches.' : 'Event not found.',
      );
    const data = decode(first(hits[0]!, 'calendar-data') ?? '');
    if (
      /^(RRULE|RDATE|RECURRENCE-ID)[:;]/im.test(data) ||
      (data.match(/^BEGIN:VEVENT/gim) ?? []).length > 1
    )
      throw new Error(
        'This event repeats. Deleting it would remove the whole series, so Lotti does not do that over CalDAV: delete it in your calendar app.',
      );
    await this.dav('DELETE', this.abs(first(hits[0]!, 'href')!, cal.id), '');
  }

  async create(
    cal: DavCalendar,
    now: number,
    e: {
      title: string;
      start: number;
      end: number;
      location?: string;
      notes?: string;
    },
  ): Promise<string> {
    const { uid, ics } = buildEvent(now, e);
    const url = cal.id.replace(/\/?$/, '/') + encodeURIComponent(uid) + '.ics';
    await this.dav('PUT', url, ics, {
      'content-type': 'text/calendar; charset=utf-8',
      'if-none-match': '*',
    });
    return uid;
  }
}
