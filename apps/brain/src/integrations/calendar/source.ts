import type { App } from '../../app.ts';
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
import { CalDav, type DavCalendar, REPEATS_REFUSED } from './caldav.ts';
import { expandFeed, type Feed, parseFeed } from './recur.ts';

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
  /** The event as the service has it now; throws when Lotti will not delete it (a whole series). */
  deletable(calendarId: string, eventId: string): Promise<CalendarEvent>;
  /** Deletes one event; a repeating one only as far as the service allows (see each backend). */
  delete(calendarId: string, eventId: string): Promise<void>;
}

const G = 'https://www.googleapis.com/calendar/v3';

export function googleBackend(app: App, acc: AccountRow): CalBackend {
  const toEvent = (e: any, id: string): CalendarEvent | undefined => {
    if (e.status === 'cancelled') return undefined;
    const allDay = !e.start?.dateTime;
    const s = Date.parse(e.start?.dateTime ?? `${e.start?.date}T00:00:00`);
    const en = Date.parse(e.end?.dateTime ?? `${e.end?.date}T00:00:00`);
    if (Number.isNaN(s)) return undefined;
    return {
      id: String(e.id),
      title: String(e.summary ?? '(no title)'),
      start: s,
      end: Number.isNaN(en) ? s + 3_600_000 : en,
      ...(e.location ? { location: String(e.location) } : {}),
      ...(allDay ? { allDay: true } : {}),
      calendar: id === 'primary' ? acc.label || 'primary' : id,
      calendarId: id,
      ...(e.recurringEventId ? { recurring: true } : {}),
    };
  };
  const eventUrl = (calendarId: string, eventId: string) =>
    `${G}/calendars/${encodeURIComponent(calendarId)}/events/${encodeURIComponent(eventId)}`;
  const deletable = async (calendarId: string, eventId: string) => {
    const e = await googleFetch(app, acc.id, eventUrl(calendarId, eventId));
    // A series itself (not one occurrence of it) has the repeat rule: deleting it would wipe every occurrence.
    if (e.recurrence)
      throw new Error(
        'That is a whole repeating series, not one occurrence: list the events again and pick the occurrence.',
      );
    const ev = toEvent(e, calendarId);
    if (!ev) throw new Error('Event not found.');
    return ev;
  };
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
          const ev = toEvent(e, id);
          if (ev) out.push(ev);
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
    deletable,
    // singleEvents=true lists occurrences with their own ids: this removes that one occurrence only,
    // and `deletable` refuses a series id even when one is passed by hand.
    async delete(calendarId, eventId) {
      await deletable(calendarId, eventId);
      await googleFetch(app, acc.id, eventUrl(calendarId, eventId), {
        method: 'DELETE',
      });
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
  const calendar = async (calendarId: string, eventId: string) => {
    // `uid#recurrence-id`: one occurrence of a series (see parseEvents).
    if (eventId.includes('#')) throw new Error(REPEATS_REFUSED);
    const cal = (await pick([calendarId]))[0];
    if (!cal) throw new Error('Calendar not found.');
    return cal;
  };
  return {
    calendars: () => dav().listCalendars(),
    async events(ids, from, to) {
      const out: CalendarEvent[] = [];
      for (const c of await pick(ids))
        out.push(
          ...(await dav().events(c, from, to)).map((e) => ({
            ...e,
            calendarId: c.id,
          })),
        );
      return out;
    },
    async deletable(calendarId, eventId) {
      return dav().deletable(await calendar(calendarId, eventId), eventId);
    },
    async delete(calendarId, eventId) {
      await dav().delete(await calendar(calendarId, eventId), eventId);
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
/** A failed fetch is not retried for this long (meeting_soon asks every minute; a hung feed takes 20 s). */
const ICS_FAIL_MS = 2 * 60_000;
const MAX_FEED = 20_000_000;
interface IcsEntry {
  url: string;
  at: number;
  feed?: Feed;
  /** Already redacted. */
  error?: string;
  /** The fetch in progress: concurrent callers share it. */
  pending?: Promise<Feed>;
}
const icsCache = new WeakMap<App, Map<string, IcsEntry>>();

/** `webcal://` is plain https; surrounding whitespace is ignored. */
export const normalizeIcsUrl = (u: string) =>
  u.trim().replace(/^webcals?:\/\//i, 'https://');

const isLoopback = (host: string) =>
  host === 'localhost' || host === '[::1]' || /^127\.\d+\.\d+\.\d+$/.test(host);

/** Only https carries the secret link (plain http to this machine is allowed for development). */
function secureUrl(url: string): boolean {
  try {
    const u = new URL(url);
    return (
      u.protocol === 'https:' ||
      (u.protocol === 'http:' && isLoopback(u.hostname))
    );
  } catch {
    return false;
  }
}

/** The secret link is a password: it must not appear in any message the app or the log can see. */
function redactUrl(msg: string, url: string): string {
  if (!url) return msg;
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

async function fetchFeed(app: App, url: string): Promise<Feed> {
  try {
    if (!secureUrl(url))
      throw new Error(
        /^http:/i.test(url)
          ? 'The link must start with https:// or webcal:// (plain http would send the secret link unencrypted).'
          : 'The link must start with https:// or webcal://.',
      );
    // Redirects are followed by hand, so every hop is checked before the secret link goes there.
    const signal = AbortSignal.timeout(20_000);
    let at = url;
    let res: Response;
    for (let hop = 0; ; hop++) {
      res = await app.fetch(at, {
        headers: { accept: 'text/calendar, */*' },
        redirect: 'manual',
        signal,
      });
      const loc = res.headers.get('location');
      if (res.status < 300 || res.status > 399 || !loc) break;
      await res.body?.cancel().catch(() => undefined);
      if (hop >= 5)
        throw new Error('The calendar link redirected too many times.');
      at = new URL(loc, at).href;
      if (!secureUrl(at))
        throw new Error(
          'The calendar link redirected to a plain http address: refused.',
        );
    }
    if (!res.ok)
      throw new Error(`The calendar link answered HTTP ${res.status}.`);
    const text = await readCapped(res, MAX_FEED);
    if (!/BEGIN:VCALENDAR/i.test(text))
      throw new Error('The link did not return a calendar (ICS) feed.');
    return parseFeed(text);
  } catch (e) {
    const cause =
      e instanceof Error ? (e.cause as Error | undefined) : undefined;
    const why =
      e instanceof Error && e.name === 'TimeoutError'
        ? 'The calendar server did not answer in time.'
        : e instanceof Error
          ? e.message
          : String(e);
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

/**
 * The parsed feed, cached 15 minutes per account (and per link: a new link is fetched at once). Concurrent
 * callers share one fetch; a failure is remembered for 2 minutes (`retryFailed`: try again at once).
 */
export async function icsFeed(
  app: App,
  acc: AccountRow,
  opts: { retryFailed?: boolean } = {},
): Promise<Feed> {
  const url = normalizeIcsUrl(app.secrets.get(`account.${acc.id}.url`) ?? '');
  if (!url)
    throw new Error('This calendar has no link yet (set it in the app).');
  let m = icsCache.get(app);
  if (!m) icsCache.set(app, (m = new Map()));
  const now = app.clock.now();
  const hit = m.get(acc.id);
  if (hit && hit.url !== url) m.delete(acc.id);
  else if (hit?.pending) return hit.pending;
  else if (hit?.feed && now - hit.at < ICS_CACHE_MS) return hit.feed;
  else if (hit?.error && !opts.retryFailed && now - hit.at < ICS_FAIL_MS)
    throw new Error(hit.error);
  const entry: IcsEntry = { url, at: now };
  const cache = m;
  entry.pending = fetchFeed(app, url).then(
    (feed) => {
      if (cache.get(acc.id) === entry)
        cache.set(acc.id, { url, at: app.clock.now(), feed });
      return feed;
    },
    (e: unknown) => {
      if (cache.get(acc.id) === entry)
        cache.set(acc.id, {
          url,
          at: app.clock.now(),
          error: e instanceof Error ? e.message : String(e),
        });
      throw e;
    },
  );
  m.set(acc.id, entry);
  return entry.pending;
}

/** Forget cached feeds of accounts that are gone (or switched off). */
function pruneIcsCache(app: App, live: AccountRow[]) {
  const m = icsCache.get(app);
  if (!m) return;
  const ids = new Set(live.map((a) => a.id));
  for (const id of m.keys()) if (!ids.has(id)) m.delete(id);
}

export function icsBackend(app: App, acc: AccountRow): CalBackend {
  return {
    calendars: async () => {
      await icsFeed(app, acc);
      return [{ id: 'ics', name: acc.label }];
    },
    async events(_ids, from, to) {
      return expandFeed(await icsFeed(app, acc), from, to, acc.label);
    },
    async create() {
      throw new Error('ICS calendars are read-only.');
    },
    // Events carry no `calendarId`, so they get no delete ref; these refuse a hand-made one clearly.
    async deletable() {
      throw new Error(
        'ICS calendars are read-only: delete it in the calendar itself.',
      );
    },
    async delete() {
      throw new Error(
        'ICS calendars are read-only: delete it in the calendar itself.',
      );
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

/**
 * `account|calendar|event`: what the agent hands back to delete an event. Only `%` and `|` are escaped, so a
 * CalDAV calendar URL stays readable (fewer tokens, and nothing for the model to re-encode).
 */
export const eventRef = (account: string, calendar: string, event: string) =>
  [account, calendar, event]
    .map((x) => x.replace(/[%|]/g, encodeURIComponent))
    .join('|');
const parseRef = (ref: string) => {
  const p = ref.split('|');
  return p.length === 3 && p.every(Boolean)
    ? ([p[0]!, p[1]!, p[2]!].map((x) => decodeURIComponent(x)) as [
        string,
        string,
        string,
      ])
    : undefined;
};

/** All calendar accounts merged. One failing account does not hide the others. */
export class MergedCalendar implements CalendarSource {
  constructor(
    private app: App,
    private backend: BackendFactory = defaultBackend,
  ) {}

  async events(from: number, to: number): Promise<CalendarEvent[]> {
    const accounts = accountsFor(this.app, 'calendar');
    pruneIcsCache(this.app, accounts);
    const out: CalendarEvent[] = [];
    const errors: string[] = [];
    let okCount = 0;
    // In parallel (one slow feed must not delay the rest); results are used in account order.
    const results = await Promise.all(
      accounts.map(async (acc) => {
        try {
          const evs = await this.backend(this.app, acc).events(
            strList(acc.config.calendars),
            from,
            to,
          );
          return { acc, evs };
        } catch (error) {
          return { acc, error };
        }
      }),
    );
    for (const r of results) {
      const { acc } = r;
      if ('error' in r) {
        noteAccountError(this.app, acc.id, r.error);
        errors.push(`${acc.label}: ${errText(r.error)}`);
        continue;
      }
      out.push(
        ...r.evs.map((e) =>
          e.calendarId
            ? { ...e, ref: eventRef(acc.id, e.calendarId, e.id) }
            : e,
        ),
      );
      touchSync(this.app, acc.id);
      okCount++;
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
        text: `"${title}" added to ${acc.label}.`,
      };
    } catch (e) {
      return { ok: false, text: `Could not add the event: ${errText(e)}` };
    }
  }

  /**
   * The account and event behind an `eventRef`, only in a calendar Lotti lists (the selected ones, or the
   * account default when none are selected): a made-up ref cannot reach other calendars.
   */
  private resolve(
    ref: unknown,
  ):
    | { acc: AccountRow; calendarId: string; eventId: string }
    | { error: string } {
    let parts: [string, string, string] | undefined;
    try {
      parts = parseRef(String(ref ?? ''));
    } catch {
      parts = undefined;
    }
    if (!parts) return { error: 'That event reference is not valid.' };
    const [accountId, calendarId, eventId] = parts;
    const acc = accountsFor(this.app, 'calendar').find(
      (a) => a.id === accountId,
    );
    if (!acc) return { error: 'That calendar account is gone.' };
    const selected = strList(acc.config.calendars);
    if (
      selected.length
        ? !selected.includes(calendarId)
        : acc.kind === 'google' && calendarId !== 'primary'
    )
      return { error: 'Lotti does not use that calendar.' };
    return { acc, calendarId, eventId };
  }

  /** The event a delete would remove, read from the service now; or why Lotti will not delete it. */
  async deletable(
    ref: unknown,
  ): Promise<{ ok: true; event: CalendarEvent } | { ok: false; text: string }> {
    const r = this.resolve(ref);
    if ('error' in r) return { ok: false, text: r.error };
    try {
      return {
        ok: true,
        event: await this.backend(this.app, r.acc).deletable(
          r.calendarId,
          r.eventId,
        ),
      };
    } catch (e) {
      return { ok: false, text: `Cannot delete that event: ${errText(e)}` };
    }
  }

  async deleteEvent(args: Record<string, unknown>): Promise<ActionOutcome> {
    const r = this.resolve(args.eventRef);
    if ('error' in r) return { ok: false, text: r.error };
    const title = String(args.title ?? 'The event');
    try {
      await this.backend(this.app, r.acc).delete(r.calendarId, r.eventId);
      touchSync(this.app, r.acc.id);
      return { ok: true, text: `"${title}" deleted from ${r.acc.label}.` };
    } catch (e) {
      return { ok: false, text: `Could not delete the event: ${errText(e)}` };
    }
  }
}
