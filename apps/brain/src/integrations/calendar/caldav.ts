import type { CalendarEvent } from '../index.ts';
import { buildEvent, parseEvents, seriesInfo } from './ics.ts';

export const REPEATS_REFUSED =
  "This event repeats, and in this calendar Lotti can only delete it as the whole series, so it doesn't. Delete it in your calendar app.";

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
    if (res.status === 412 && method === 'DELETE')
      throw new Error('The event changed in the meantime: list it again.');
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

  /** The resource holding the event with exactly this UID (text-match is a substring match). */
  private async find(
    cal: DavCalendar,
    uid: string,
  ): Promise<{ href: string; etag?: string; data: string }> {
    const body =
      `<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>` +
      `<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:prop-filter name="UID">` +
      `<c:text-match collation="i;octet">${uid.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</c:text-match>` +
      `</c:prop-filter></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>`;
    const xml = (await this.dav('REPORT', cal.id, body, { depth: '1' })).text;
    const hits = elements(xml, 'response')
      .map((r) => ({
        href: first(r, 'href'),
        etag: first(r, 'getetag'),
        data: decode(first(r, 'calendar-data') ?? ''),
      }))
      .filter((r) => r.href && seriesInfo(r.data).uids.includes(uid));
    if (hits.length !== 1)
      throw new Error(
        hits.length ? 'More than one event matches.' : 'Event not found.',
      );
    const hit = hits[0]!;
    return {
      href: this.abs(hit.href!, cal.id),
      data: hit.data,
      ...(hit.etag ? { etag: decode(hit.etag).trim() } : {}),
    };
  }

  /**
   * The event with this UID, as the server has it now. A repeating one (RRULE / RDATE / RECURRENCE-ID /
   * several VEVENTs) is refused: the resource is the whole series, and deleting it would wipe all of it.
   */
  async deletable(cal: DavCalendar, uid: string): Promise<CalendarEvent> {
    const { data } = await this.find(cal, uid);
    if (seriesInfo(data).repeats) throw new Error(REPEATS_REFUSED);
    const ev = parseEvents(data, cal.name)[0];
    if (!ev) throw new Error('Event not found.');
    return ev;
  }

  /** Deletes one non-repeating event by UID; If-Match so a resource changed since the check is not deleted. */
  async delete(cal: DavCalendar, uid: string): Promise<void> {
    const { href, etag, data } = await this.find(cal, uid);
    if (seriesInfo(data).repeats) throw new Error(REPEATS_REFUSED);
    await this.dav('DELETE', href, '', etag ? { 'if-match': etag } : {});
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
