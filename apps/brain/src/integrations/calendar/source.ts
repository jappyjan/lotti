import type { App } from '../../app.ts';
import { isoLocal } from '../../util/clock.ts';
import {
  accountsFor,
  errText,
  noteAccountError,
  strList,
  touchSync,
} from '../accounts.ts';
import { googleFetch } from '../google/oauth.ts';
import type {
  AccountRow,
  ActionOutcome,
  CalendarEvent,
  CalendarSource,
} from '../index.ts';
import { CalDav, type DavCalendar } from './caldav.ts';
import { expandEvents } from './recur.ts';

export interface CalendarInfo {
  id: string;
  name: string;
}
interface NewEvent {
  title: string;
  start: number;
  end: number;
  location?: string;
  notes?: string;
  attendees?: string[];
}

/** One calendar service of one account. */
export interface CalBackend {
  calendars(): Promise<CalendarInfo[]>;
  /** `ids` empty/undefined = the account default (google: primary, caldav: all). */
  events(ids: string[], from: number, to: number): Promise<CalendarEvent[]>;
  create(calendarId: string | undefined, e: NewEvent): Promise<string>;
}

const G = 'https://www.googleapis.com/calendar/v3';

export function googleBackend(app: App, acc: AccountRow): CalBackend {
  return {
    async calendars() {
      const j = await googleFetch(
        app,
        acc.id,
        `${G}/users/me/calendarList?minAccessRole=reader`,
      );
      return (j.items ?? []).map((c: any) => ({
        id: String(c.id),
        name: String(c.summaryOverride ?? c.summary ?? c.id),
      }));
    },
    async events(ids, from, to) {
      const out: CalendarEvent[] = [];
      for (const id of ids.length ? ids : ['primary']) {
        const q = new URLSearchParams({
          timeMin: new Date(from).toISOString(),
          timeMax: new Date(to).toISOString(),
          singleEvents: 'true',
          orderBy: 'startTime',
          maxResults: '100',
        });
        const j = await googleFetch(
          app,
          acc.id,
          `${G}/calendars/${encodeURIComponent(id)}/events?${q}`,
        );
        for (const e of j.items ?? []) {
          if (e.status === 'cancelled') continue;
          const allDay = !e.start?.dateTime;
          const s = Date.parse(
            e.start?.dateTime ?? `${e.start?.date}T00:00:00`,
          );
          const en = Date.parse(e.end?.dateTime ?? `${e.end?.date}T00:00:00`);
          if (Number.isNaN(s)) continue;
          out.push({
            id: String(e.id),
            title: String(e.summary ?? '(no title)'),
            start: s,
            end: Number.isNaN(en) ? s + 3_600_000 : en,
            ...(e.location ? { location: String(e.location) } : {}),
            ...(allDay ? { allDay: true } : {}),
            calendar: id === 'primary' ? acc.label || 'primary' : id,
          });
        }
      }
      return out;
    },
    async create(calendarId, e) {
      const j = await googleFetch(
        app,
        acc.id,
        `${G}/calendars/${encodeURIComponent(calendarId ?? 'primary')}/events`,
        {
          method: 'POST',
          body: {
            summary: e.title,
            start: { dateTime: new Date(e.start).toISOString() },
            end: { dateTime: new Date(e.end).toISOString() },
            ...(e.location ? { location: e.location } : {}),
            ...(e.notes ? { description: e.notes } : {}),
            ...(e.attendees?.length
              ? { attendees: e.attendees.map((email) => ({ email })) }
              : {}),
          },
        },
      );
      return String(j.id ?? '');
    },
  };
}

export function davFor(app: App, acc: AccountRow): CalDav {
  const password = app.secrets.get(`account.${acc.id}.password`);
  const username = String(acc.config.username ?? '');
  const url =
    acc.kind === 'icloud'
      ? String(acc.config.caldavUrl ?? 'https://caldav.icloud.com/')
      : String(acc.config.url ?? '');
  if (!url || !username || !password)
    throw new Error(
      'CalDAV needs url, username and password (set them in the app).',
    );
  return new CalDav({ url, username, password }, (...a) => app.fetch(...a));
}

/**
 * Discovered CalDAV calendars per app + account, for 1 h (discovery is 3 PROPFINDs; meeting-soon asks every
 * minute). Keyed on the account config, so accounts.update / set_calendars invalidate it.
 */
const CAL_CACHE_MS = 3_600_000;
const calCache = new WeakMap<
  App,
  Map<string, { key: string; at: number; cals: DavCalendar[] }>
>();

export function caldavBackend(app: App, acc: AccountRow): CalBackend {
  const dav = () => davFor(app, acc);
  const discover = async (): Promise<DavCalendar[]> => {
    let m = calCache.get(app);
    if (!m) calCache.set(app, (m = new Map()));
    // Any account edit (url, username, selection, ...) changes the key and forces a fresh discovery.
    const key = JSON.stringify(acc.config);
    const hit = m.get(acc.id);
    if (hit && hit.key === key && app.clock.now() - hit.at < CAL_CACHE_MS)
      return hit.cals;
    const cals = await dav().listCalendars();
    m.set(acc.id, { key, at: app.clock.now(), cals });
    return cals;
  };
  const pick = async (ids: string[]): Promise<DavCalendar[]> => {
    const all = await discover();
    return ids.length ? all.filter((c) => ids.includes(c.id)) : all;
  };
  return {
    calendars: () => dav().listCalendars(),
    async events(ids, from, to) {
      const out: CalendarEvent[] = [];
      for (const c of await pick(ids))
        out.push(...(await dav().events(c, from, to)));
      return out;
    },
    async create(calendarId, e) {
      const cal = (await pick(calendarId ? [calendarId] : []))[0];
      if (!cal) throw new Error('No CalDAV calendar to add the event to.');
      return dav().create(cal, app.clock.now(), e);
    },
  };
}

// ---- ICS subscription (secret link of a Google / Microsoft 365 calendar), read-only -------------------------

const ICS_CACHE_MS = 15 * 60_000;
const MAX_FEED = 20_000_000;
const icsCache = new WeakMap<
  App,
  Map<string, { url: string; at: number; text: string }>
>();

/** `webcal://` is plain https; surrounding whitespace is ignored. */
export const normalizeIcsUrl = (u: string) =>
  u.trim().replace(/^webcals?:\/\//i, 'https://');

/** The secret link is a password: it must not appear in any message the app or the log can see. */
function redactUrl(msg: string, url: string): string {
  let out = msg.split(url).join('[calendar link]');
  try {
    const u = new URL(url);
    for (const part of [u.pathname + u.search, u.search, u.pathname])
      if (part.length > 3) out = out.split(part).join('[…]');
  } catch {
    /* not a URL: nothing else to hide */
  }
  return out;
}

/** The body as text, stopping as soon as more than `max` bytes arrive (a huge reply is never held in memory). */
async function readCapped(res: Response, max: number): Promise<string> {
  const tooBig = () => new Error('The calendar feed is too big.');
  if (Number(res.headers.get('content-length')) > max) throw tooBig();
  if (!res.body) {
    const text = await res.text();
    if (text.length > max) throw tooBig();
    return text;
  }
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel().catch(() => undefined);
      throw tooBig();
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString('utf8');
}

/** One readable line for a network failure (no raw OpenSSL dumps). */
function networkReason(cause: Error | undefined): string {
  const msg = cause?.message ?? '';
  if (/ssl|tls|certificate/i.test(msg))
    return ' (secure connection failed: is the link https?)';
  const line = msg.split('\n')[0]?.trim();
  return line ? ` (${line})` : '';
}

/** The feed text, cached 15 minutes per account (and per link: a new link is fetched at once). */
export async function icsFeed(app: App, acc: AccountRow): Promise<string> {
  const raw = app.secrets.get(`account.${acc.id}.url`);
  if (!raw)
    throw new Error('This calendar has no link yet (set it in the app).');
  const url = normalizeIcsUrl(raw);
  let m = icsCache.get(app);
  if (!m) icsCache.set(app, (m = new Map()));
  const hit = m.get(acc.id);
  if (hit && hit.url === url && app.clock.now() - hit.at < ICS_CACHE_MS)
    return hit.text;
  try {
    if (!/^https?:\/\//i.test(url)) throw new Error('The link must be https.');
    const res = await app.fetch(url, {
      headers: { accept: 'text/calendar, */*' },
      signal: AbortSignal.timeout(20_000),
    });
    if (!res.ok)
      throw new Error(`The calendar link answered HTTP ${res.status}.`);
    const text = await readCapped(res, MAX_FEED);
    if (!/BEGIN:VCALENDAR/i.test(text))
      throw new Error('The link did not return a calendar (ICS) feed.');
    m.set(acc.id, { url, at: app.clock.now(), text });
    return text;
  } catch (e) {
    const cause =
      e instanceof Error ? (e.cause as Error | undefined) : undefined;
    const why = e instanceof Error ? e.message : String(e);
    throw new Error(
      redactUrl(
        why === 'fetch failed'
          ? `Cannot reach the calendar server${networkReason(cause)}.`
          : why,
        url,
      ),
    );
  }
}

export function icsBackend(app: App, acc: AccountRow): CalBackend {
  return {
    calendars: async () => {
      await icsFeed(app, acc);
      return [{ id: 'ics', name: acc.label }];
    },
    async events(_ids, from, to) {
      return expandEvents(await icsFeed(app, acc), from, to, acc.label);
    },
    async create() {
      throw new Error('ICS calendars are read-only.');
    },
  };
}

export type BackendFactory = (app: App, acc: AccountRow) => CalBackend;
export const defaultBackend: BackendFactory = (app, acc) =>
  acc.kind === 'google'
    ? googleBackend(app, acc)
    : acc.kind === 'ics'
      ? icsBackend(app, acc)
      : caldavBackend(app, acc);

/** All calendar accounts merged. One failing account does not hide the others. */
export class MergedCalendar implements CalendarSource {
  constructor(
    private app: App,
    private backend: BackendFactory = defaultBackend,
  ) {}

  async events(from: number, to: number): Promise<CalendarEvent[]> {
    const accounts = accountsFor(this.app, 'calendar');
    const out: CalendarEvent[] = [];
    const errors: string[] = [];
    let okCount = 0;
    for (const acc of accounts) {
      try {
        out.push(
          ...(await this.backend(this.app, acc).events(
            strList(acc.config.calendars),
            from,
            to,
          )),
        );
        touchSync(this.app, acc.id);
        okCount++;
      } catch (e) {
        noteAccountError(this.app, acc.id, e);
        errors.push(`${acc.label}: ${errText(e)}`);
      }
    }
    if (errors.length && !okCount) throw new Error(errors.join('; '));
    if (errors.length)
      this.app.log.warn('calendar partly failed', errors.join('; '));
    // The same invite can show up in several accounts: dedupe by title + start.
    const seen = new Set<string>();
    return out
      .filter((e) => e.end > from && e.start < to)
      .filter((e) => {
        const k = `${e.title}|${e.start}`;
        return seen.has(k) ? false : (seen.add(k), true);
      })
      .sort((a, b) => a.start - b.start);
  }

  async next(from: number): Promise<CalendarEvent | undefined> {
    const day = 86_400_000;
    return (await this.events(from, from + 14 * day)).find(
      (e) => e.start >= from,
    );
  }

  async createEvent(args: Record<string, unknown>): Promise<ActionOutcome> {
    const title = String(args.title ?? '').trim();
    const start = Date.parse(String(args.start));
    const end = Date.parse(String(args.end));
    if (!title || Number.isNaN(start) || Number.isNaN(end))
      return {
        ok: false,
        text: 'The event needs a title and valid start and end.',
      };
    const all = accountsFor(this.app, 'calendar');
    const asked = all.find((a) => a.id === args.accountId);
    if (asked?.kind === 'ics')
      return {
        ok: false,
        text: `${asked.label} is read-only (ICS subscription).`,
      };
    // Subscriptions are never a write target.
    const accounts = all.filter((a) => a.kind !== 'ics');
    const acc =
      asked ??
      accounts.find((a) => a.config.writeDefault === true) ??
      accounts[0];
    if (!acc)
      return {
        ok: false,
        text: all.length
          ? 'Only read-only calendars are connected: add a Google or CalDAV calendar to create events.'
          : 'No calendar is connected yet.',
      };
    try {
      const selected = strList(acc.config.calendars);
      await this.backend(this.app, acc).create(selected[0], {
        title,
        start,
        end,
        ...(typeof args.location === 'string'
          ? { location: args.location }
          : {}),
        ...(typeof args.notes === 'string' ? { notes: args.notes } : {}),
        ...(Array.isArray(args.attendees)
          ? { attendees: strList(args.attendees) }
          : {}),
      });
      touchSync(this.app, acc.id);
      return {
        ok: true,
        text: `"${title}" added (${isoLocal(start)}) to ${acc.label}.`,
      };
    } catch (e) {
      return { ok: false, text: `Could not add the event: ${errText(e)}` };
    }
  }
}
