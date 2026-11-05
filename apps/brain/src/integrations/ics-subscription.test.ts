import assert from 'node:assert/strict';
import { test } from 'node:test';
import { makeApp } from '../testing/helpers.ts';
import { parseEvents, zonedToEpoch } from './calendar/ics.ts';
import { expandEvents } from './calendar/recur.ts';
import { defaultBackend, MergedCalendar } from './calendar/source.ts';
import { registerIntegrations } from './register.ts';
import { mockFetch } from './testing.ts';

const cal = (...events: string[]) =>
  `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${events.map((e) => `BEGIN:VEVENT\r\n${e}\r\nEND:VEVENT\r\n`).join('')}END:VCALENDAR\r\n`;
const ev = (...lines: string[]) => lines.join('\r\n');
const range = (a: string, b: string) => [Date.parse(a), Date.parse(b)] as const;
const starts = (r: ReturnType<typeof expandEvents>) => r.map((e) => e.start);

test('rrule: weekly BYDAY with interval', () => {
  const ics = cal(
    ev(
      'UID:w',
      'DTSTART:20261102T090000Z',
      'DTEND:20261102T093000Z',
      'RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE',
      'SUMMARY:Sync',
    ),
  );
  const r = expandEvents(
    ics,
    ...range('2026-11-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  // Mon 2 Nov, Wed 4 Nov, Mon 16 Nov, Wed 18 Nov, Mon 30 Nov
  assert.deepEqual(
    r.map((e) => new Date(e.start).toISOString().slice(0, 10)),
    ['2026-11-02', '2026-11-04', '2026-11-16', '2026-11-18', '2026-11-30'],
  );
  assert.equal(r[0]!.end - r[0]!.start, 30 * 60_000);
  assert.equal(new Set(r.map((e) => e.id)).size, r.length);
});

test('rrule: monthly ordinals (2nd Tuesday, last Friday) and BYMONTHDAY -1', () => {
  const second = expandEvents(
    cal(
      ev(
        'UID:a',
        'DTSTART:20261110T100000Z',
        'DTEND:20261110T110000Z',
        'RRULE:FREQ=MONTHLY;BYDAY=2TU',
        'SUMMARY:A',
      ),
    ),
    ...range('2026-11-01T00:00:00Z', '2027-02-01T00:00:00Z'),
  );
  assert.deepEqual(
    second.map((e) => new Date(e.start).toISOString().slice(0, 10)),
    ['2026-11-10', '2026-12-08', '2027-01-12'],
  );
  const last = expandEvents(
    cal(
      ev(
        'UID:b',
        'DTSTART:20261127T100000Z',
        'DTEND:20261127T110000Z',
        'RRULE:FREQ=MONTHLY;BYDAY=-1FR',
        'SUMMARY:B',
      ),
    ),
    ...range('2026-11-01T00:00:00Z', '2027-01-01T00:00:00Z'),
  );
  assert.deepEqual(
    last.map((e) => new Date(e.start).toISOString().slice(0, 10)),
    ['2026-11-27', '2026-12-25'],
  );
  const eom = expandEvents(
    cal(
      ev(
        'UID:c',
        'DTSTART:20261130T100000Z',
        'DTEND:20261130T110000Z',
        'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1',
        'SUMMARY:C',
      ),
    ),
    ...range('2026-11-01T00:00:00Z', '2027-03-01T00:00:00Z'),
  );
  assert.deepEqual(
    eom.map((e) => new Date(e.start).toISOString().slice(0, 10)),
    ['2026-11-30', '2026-12-31', '2027-01-31', '2027-02-28'],
  );
});

test('rrule: COUNT and UNTIL stop the series, also when started before the window', () => {
  const count = expandEvents(
    cal(
      ev(
        'UID:c',
        'DTSTART:20261101T080000Z',
        'DTEND:20261101T090000Z',
        'RRULE:FREQ=DAILY;COUNT=3',
        'SUMMARY:C',
      ),
    ),
    ...range('2026-11-02T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  assert.equal(count.length, 2); // 1st is before the window, 2nd and 3rd inside
  const until = expandEvents(
    cal(
      ev(
        'UID:u',
        'DTSTART:20261101T080000Z',
        'DTEND:20261101T090000Z',
        'RRULE:FREQ=DAILY;UNTIL=20261105T080000Z',
        'SUMMARY:U',
      ),
    ),
    ...range('2026-11-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  assert.equal(until.length, 5);
  const dayUntil = expandEvents(
    cal(
      ev(
        'UID:d',
        'DTSTART:20261101T080000Z',
        'DTEND:20261101T090000Z',
        'RRULE:FREQ=DAILY;UNTIL=20261103',
        'SUMMARY:D',
      ),
    ),
    ...range('2026-11-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  assert.equal(dayUntil.length, 3);
});

test('rrule: EXDATE removes an instance, RECURRENCE-ID moves one and can cancel one', () => {
  const ics = cal(
    ev(
      'UID:s',
      'DTSTART:20261102T090000Z',
      'DTEND:20261102T100000Z',
      'RRULE:FREQ=DAILY;COUNT=5',
      'EXDATE:20261103T090000Z',
      'SUMMARY:Daily',
    ),
    ev(
      'UID:s',
      'RECURRENCE-ID:20261104T090000Z',
      'DTSTART:20261104T150000Z',
      'DTEND:20261104T160000Z',
      'SUMMARY:Daily (moved)',
    ),
    ev(
      'UID:s',
      'RECURRENCE-ID:20261105T090000Z',
      'DTSTART:20261105T090000Z',
      'STATUS:CANCELLED',
      'SUMMARY:Daily',
    ),
  );
  const r = expandEvents(
    ics,
    ...range('2026-11-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  assert.deepEqual(
    r.map((e) => [new Date(e.start).toISOString().slice(0, 16), e.title]),
    [
      ['2026-11-02T09:00', 'Daily'],
      ['2026-11-04T15:00', 'Daily (moved)'],
      ['2026-11-06T09:00', 'Daily'],
    ],
  );
});

test('rrule: TZID keeps wall-clock time across DST; Windows zone names work', () => {
  const ics = cal(
    ev(
      'UID:t',
      'DTSTART;TZID=Europe/Berlin:20261023T090000',
      'DTEND;TZID=Europe/Berlin:20261023T100000',
      'RRULE:FREQ=WEEKLY;COUNT=2',
      'SUMMARY:Berlin',
    ),
    ev(
      'UID:t2',
      'DTSTART;TZID=W. Europe Standard Time:20261030T090000',
      'DTEND;TZID=W. Europe Standard Time:20261030T100000',
      'SUMMARY:Win',
    ),
  );
  const r = expandEvents(
    ics,
    ...range('2026-10-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  // 23 Oct is CEST (UTC+2), 30 Oct is CET after the switch on 25 Oct (UTC+1).
  assert.deepEqual(
    r
      .map((e) => [e.title, new Date(e.start).toISOString().slice(0, 16)])
      .sort(),
    [
      ['Berlin', '2026-10-23T07:00'],
      ['Berlin', '2026-10-30T08:00'],
      ['Win', '2026-10-30T08:00'],
    ],
  );
});

test('rrule: unsupported or hostile rules never invent events, loop or crash', () => {
  const [from, to] = range('2026-11-05T00:00:00Z', '2026-12-05T00:00:00Z');
  const one = (rule: string) =>
    expandEvents(
      cal(ev('UID:u', 'SUMMARY:T', 'DTSTART:20261101T090000Z', rule)),
      from,
      to,
    );
  // Parts we cannot evaluate: the series is not expanded (ignoring them would mean 22 phantom events).
  assert.equal(
    one('RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1').length,
    0,
  );
  assert.equal(one('RRULE:FREQ=YEARLY;BYWEEKNO=20').length, 0);
  assert.equal(one('RRULE:FREQ=HOURLY').length, 0);
  // A date beyond the calendar's range ends the series; no NaN events.
  const huge = one('RRULE:FREQ=DAILY;INTERVAL=99999999999');
  assert.equal(huge.length, 0);
  assert.ok(huge.every((e) => Number.isFinite(e.start)));
  // Garbage, zero interval and an endless rule over a long-past start stay bounded.
  assert.equal(one('RRULE:FREQ=;;;BYDAY=ZZ;COUNT=abc').length, 0);
  assert.equal(one('RRULE:FREQ=DAILY;INTERVAL=0').length, 30);
  const old = expandEvents(
    cal(
      ev('UID:o', 'SUMMARY:T', 'DTSTART:19860101T090000Z', 'RRULE:FREQ=DAILY'),
    ),
    from,
    to,
  );
  assert.equal(old.length, 30);
  // One feed cannot return an unbounded number of events.
  const many = cal(
    ...Array.from({ length: 6000 }, (_, i) =>
      ev(`UID:m${i}`, 'SUMMARY:T', 'DTSTART:20261110T090000Z'),
    ),
  );
  assert.equal(expandEvents(many, from, to).length, 5000);
});

test('rrule: all-day events, multi-day spans and yearly', () => {
  const ics = cal(
    ev(
      'UID:h',
      'DTSTART;VALUE=DATE:20261224',
      'DTEND;VALUE=DATE:20261227',
      'RRULE:FREQ=YEARLY',
      'SUMMARY:Holiday',
    ),
  );
  const r = expandEvents(
    ics,
    ...range('2026-12-01T00:00:00', '2028-12-31T00:00:00'),
  );
  assert.equal(r.length, 3);
  assert.ok(r.every((e) => e.allDay === true));
  assert.equal(r[0]!.start, new Date(2026, 11, 24).getTime()); // local midnight
  assert.equal(new Date(r[1]!.start).getFullYear(), 2027);
  assert.equal(new Date(r[0]!.end).getDate(), 27);
  const in26 = expandEvents(
    ics,
    new Date(2026, 11, 26, 12).getTime(),
    new Date(2026, 11, 26, 13).getTime(),
  );
  assert.equal(in26.length, 1); // overlaps the window although it started earlier
});

test('plain events: window filter, cancelled ones are dropped', () => {
  const ics = cal(
    ev(
      'UID:1',
      'DTSTART:20261103T090000Z',
      'DTEND:20261103T100000Z',
      'SUMMARY:In',
    ),
    ev(
      'UID:2',
      'DTSTART:20261201T090000Z',
      'DTEND:20261201T100000Z',
      'SUMMARY:Out',
    ),
    ev('UID:3', 'DTSTART:20261104T090000Z', 'STATUS:CANCELLED', 'SUMMARY:Gone'),
  );
  const r = expandEvents(
    ics,
    ...range('2026-11-01T00:00:00Z', '2026-11-30T00:00:00Z'),
  );
  assert.deepEqual(
    r.map((e) => e.title),
    ['In'],
  );
  assert.deepEqual(starts(r), [Date.UTC(2026, 10, 3, 9)]);
});

// ---- account kind ics ----------------------------------------------------------------------------------------

const SECRET =
  'https://outlook.office365.com/owa/calendar/abc123SECRET/reachcalendar.ics';
const FEED = cal(
  ev(
    'UID:m1',
    'DTSTART:20261103T090000Z',
    'DTEND:20261103T093000Z',
    'RRULE:FREQ=DAILY;COUNT=3',
    'SUMMARY:Standup',
  ),
  ev(
    'UID:m2',
    'DTSTART:20261104T120000Z',
    'DTEND:20261104T130000Z',
    'SUMMARY:Lunch',
  ),
);

async function icsApp(
  res?: () => Response | unknown,
  extra: Parameters<typeof mockFetch>[0] = [],
) {
  const m = mockFetch([
    ...extra,
    {
      m: 'GET',
      u: 'outlook.office365.com',
      res:
        res ??
        (() =>
          new Response(FEED, { headers: { 'content-type': 'text/calendar' } })),
    },
  ]);
  const t = makeApp({ fetch: m.fetch });
  registerIntegrations(t.app);
  const op = async (n: string, i: unknown) =>
    (await t.app.ops.invoke(n, i, 'app')) as any;
  const id = (await op('accounts.add', { kind: 'ics', label: 'Work' })).result
    .id as string;
  return { t, m, op, id };
}

test('ics account: webcal link, check reports the event count, link never listed', async () => {
  const { t, m, op, id } = await icsApp();
  await op('accounts.set_credential', {
    id,
    key: 'url',
    value: SECRET.replace('https://', 'webcal://'),
  });
  const c = (await op('accounts.check', { id })).result;
  assert.deepEqual([c.ok, c.status, c.detail], [true, 'ok', '2 events']);
  assert.ok(m.seen[0]!.url.startsWith('https://outlook'));
  const list = JSON.stringify((await op('accounts.list', {})).result);
  assert.ok(!list.includes('SECRET') && !list.includes('office365'));
  const ev = await t.app.integrations.calendar!.events(
    Date.parse('2026-11-03T00:00:00Z'),
    Date.parse('2026-11-06T00:00:00Z'),
  );
  assert.deepEqual(
    ev.map((e) => e.title),
    ['Standup', 'Standup', 'Lunch', 'Standup'],
  );
  assert.equal(ev[0]!.calendar, 'Work');
});

test('ics account: cached for 15 minutes, a new link is fetched at once', async () => {
  const { t, m, op, id } = await icsApp();
  await op('accounts.set_credential', { id, key: 'url', value: SECRET });
  const from = Date.parse('2026-11-03T00:00:00Z');
  const cal = t.app.integrations.calendar!;
  await cal.events(from, from + 86_400_000);
  await cal.events(from, from + 86_400_000);
  assert.equal(m.seen.length, 1);
  t.clock.advance(16 * 60_000);
  await cal.events(from, from + 86_400_000);
  assert.equal(m.seen.length, 2);
  await op('accounts.set_credential', {
    id,
    key: 'url',
    value: SECRET + '?x=1',
  });
  await cal.events(from, from + 86_400_000);
  assert.equal(m.seen.length, 3);
});

test('ics account: failing feed does not hide other calendars; errors never contain the link', async () => {
  const bad = await icsApp(() => new Response('nope', { status: 500 }));
  await bad.op('accounts.set_credential', {
    id: bad.id,
    key: 'url',
    value: SECRET,
  });
  const chk = (await bad.op('accounts.check', { id: bad.id })).result;
  assert.equal(chk.ok, false);
  assert.ok(!chk.error.includes('SECRET'));

  // a second, working ics account in the same app
  const second = (await bad.op('accounts.add', { kind: 'ics', label: 'Other' }))
    .result.id;
  await bad.op('accounts.set_credential', {
    id: second,
    key: 'url',
    value: 'https://good.example/cal.ics',
  });
  bad.t.setFetch(
    mockFetch([
      { u: 'office365', res: () => new Response('x', { status: 500 }) },
      { u: 'good.example', res: () => new Response(FEED) },
    ]).fetch,
  );
  const ev = await bad.t.app.integrations.calendar!.events(
    Date.parse('2026-11-03T00:00:00Z'),
    Date.parse('2026-11-06T00:00:00Z'),
  );
  assert.deepEqual(
    ev.map((e) => e.title),
    ['Standup', 'Standup', 'Lunch', 'Standup'],
  );
  const rows = JSON.stringify((await bad.op('accounts.list', {})).result);
  assert.ok(!rows.includes('SECRET'));
  const failed = (await bad.op('accounts.list', {})).result.find(
    (a: any) => a.id === bad.id,
  );
  assert.equal(failed.status, 'error');
});

test('ics account: unreachable host error is redacted', async () => {
  const { op, id } = await icsApp(() => {
    throw new TypeError(`fetch failed for ${SECRET}`);
  });
  await op('accounts.set_credential', { id, key: 'url', value: SECRET });
  const chk = (await op('accounts.check', { id })).result;
  assert.equal(chk.ok, false);
  assert.ok(!chk.error.includes('SECRET'), chk.error);
});

test('ics account: a blank or non-http link gets one plain sentence', async () => {
  const { op, id } = await icsApp(() => {
    throw new Error('the feed must not be fetched');
  });
  for (const [value, want] of [
    ['   ', /no link yet/],
    ['not a url', /must start with https/],
    ['ftp://x.test/a.ics?k=SECRET', /must start with https/],
  ] as const) {
    await op('accounts.set_credential', { id, key: 'url', value });
    const chk = (await op('accounts.check', { id })).result;
    assert.equal(chk.ok, false);
    assert.match(chk.error, want);
    assert.ok(!chk.error.includes('[calendar link]'), chk.error);
    assert.ok(!chk.error.includes('SECRET'), chk.error);
  }
});

test('ics account: a feed that never answers says so in plain words', async () => {
  const { op, id } = await icsApp(() => {
    throw new DOMException(
      'The operation was aborted due to timeout',
      'TimeoutError',
    );
  });
  await op('accounts.set_credential', { id, key: 'url', value: SECRET });
  const chk = (await op('accounts.check', { id })).result;
  assert.equal(chk.ok, false);
  assert.equal(chk.error, 'The calendar server did not answer in time.');
});

test('ics account: read-only, never the write target', async () => {
  const { t, op, id } = await icsApp();
  await op('accounts.set_credential', { id, key: 'url', value: SECRET });
  const cal = t.app.integrations.calendar!;
  const r = await cal.createEvent!({
    title: 'x',
    start: '2026-11-05T10:00:00Z',
    end: '2026-11-05T11:00:00Z',
  });
  assert.equal(r.ok, false);
  assert.match(r.text, /read-only/);
  const r2 = await cal.createEvent!({
    title: 'x',
    start: '2026-11-05T10:00:00Z',
    end: '2026-11-05T11:00:00Z',
    accountId: id,
  });
  assert.match(r2.text, /read-only/);
  // writeDefault on an ics account is ignored when a real calendar exists
  await op('accounts.update', { id, config: { writeDefault: true } });
  const { defaultBackend } = await import('./calendar/source.ts');
  await assert.rejects(
    defaultBackend(
      t.app,
      (await import('../ops/integration-ops.ts')).accountRow(t.app, id)!,
    ).create(undefined, { title: 'x', start: 0, end: 1 }),
    /read-only/,
  );
});

test('ics account: an oversized feed is refused while streaming, TLS failures stay readable', async () => {
  // Declared too big: refused from the header alone.
  const a = await icsApp(
    () =>
      new Response('BEGIN:VCALENDAR', {
        headers: { 'content-length': String(21_000_000) },
      }),
  );
  await a.op('accounts.set_credential', {
    id: a.id,
    key: 'url',
    value: SECRET,
  });
  const big = (await a.op('accounts.check', { id: a.id })).result;
  assert.match(big.error, /too big/);

  // No length header: the stream is cut off after the cap, the rest is never read.
  let pulled = 0;
  const chunk = new Uint8Array(1_000_000);
  const stream = new ReadableStream<Uint8Array>({
    pull(c) {
      pulled++;
      c.enqueue(chunk);
    },
  });
  const b = await icsApp(() => new Response(stream));
  await b.op('accounts.set_credential', {
    id: b.id,
    key: 'url',
    value: SECRET,
  });
  assert.match(
    (await b.op('accounts.check', { id: b.id })).result.error,
    /too big/,
  );
  assert.ok(pulled < 40, `read ${pulled} chunks`);

  // Raw OpenSSL text is replaced by one readable sentence, still without the link.
  const c = await icsApp(() => {
    throw Object.assign(new TypeError('fetch failed'), {
      cause: new Error(
        '80E1:error:0A00010B:SSL routines:wrong version number\n',
      ),
    });
  });
  await c.op('accounts.set_credential', {
    id: c.id,
    key: 'url',
    value: SECRET,
  });
  const tls = (await c.op('accounts.check', { id: c.id })).result.error;
  assert.match(tls, /secure connection failed/);
  assert.ok(!/openssl|\n/i.test(tls), tls);
});

test('ics account: events carry no delete ref and a hand-made one is refused', async () => {
  const { t, op, id } = await icsApp();
  await op('accounts.set_credential', { id, key: 'url', value: SECRET });
  const cal = t.app.integrations.calendar as any;
  const from = Date.parse('2026-11-03T00:00:00Z');
  const evs = await cal.events(from, from + 3 * 86_400_000);
  assert.ok(evs.length > 0 && evs.every((e: any) => !e.ref));
  const r = await cal.deleteEvent({ eventRef: `${id}|ics|m2`, title: 'Lunch' });
  assert.equal(r.ok, false);
  assert.match(r.text, /read-only/);
  assert.match((await cal.deletable(`${id}|ics|m2`)).text, /read-only/);
});

// ---- review fixes ---------------------------------------------------------------------------------------------

const iso = (r: ReturnType<typeof expandEvents>) =>
  r.map((e) => new Date(e.start).toISOString().slice(0, 16));

test('rrule: a daily series started in 1970 still shows every day of a window in 2026', () => {
  const [from, to] = range('2026-11-05T00:00:00Z', '2026-12-05T00:00:00Z');
  const t0 = performance.now();
  const r = expandEvents(
    cal(
      ev('UID:o', 'SUMMARY:T', 'DTSTART:19700101T090000Z', 'RRULE:FREQ=DAILY'),
    ),
    from,
    to,
  );
  assert.equal(r.length, 30);
  assert.equal(r[0]!.start, Date.UTC(2026, 10, 5, 9));
  assert.ok(performance.now() - t0 < 200);
});

test('rrule: an impossible rule returns quickly with no events', () => {
  const [from, to] = range('2026-11-05T00:00:00Z', '2026-12-05T00:00:00Z');
  const t0 = performance.now();
  const r = expandEvents(
    cal(
      ev(
        'UID:x',
        'SUMMARY:T',
        'DTSTART:20200106T090000Z',
        'RRULE:FREQ=YEARLY;BYDAY=60MO',
      ),
    ),
    from,
    to,
  );
  assert.deepEqual(r, []);
  assert.ok(performance.now() - t0 < 150, `${performance.now() - t0} ms`);
});

test('rrule: a date-only UNTIL ends on that day in the event zone, whatever the server zone', () => {
  // 22:00 New York is 03:00 UTC the next day: still on the UNTIL day for the event.
  const r = expandEvents(
    cal(
      ev(
        'UID:ny',
        'SUMMARY:NY',
        'DTSTART;TZID=America/New_York:20261101T220000',
        'DTEND;TZID=America/New_York:20261101T230000',
        'RRULE:FREQ=DAILY;UNTIL=20261103',
      ),
    ),
    ...range('2026-11-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  assert.deepEqual(iso(r), [
    '2026-11-02T03:00',
    '2026-11-03T03:00',
    '2026-11-04T03:00',
  ]);
});

test('rrule: EXDATE and RECURRENCE-ID with TZID on a TZID series', () => {
  const ics = cal(
    ev(
      'UID:b',
      'DTSTART;TZID=Europe/Berlin:20261102T090000',
      'DTEND;TZID=Europe/Berlin:20261102T100000',
      'RRULE:FREQ=DAILY;COUNT=4',
      'EXDATE;TZID=Europe/Berlin:20261103T090000',
      'SUMMARY:Daily',
    ),
    ev(
      'UID:b',
      'RECURRENCE-ID;TZID=Europe/Berlin:20261104T090000',
      'DTSTART;TZID=Europe/Berlin:20261104T150000',
      'DTEND;TZID=Europe/Berlin:20261104T160000',
      'SUMMARY:Daily (moved)',
    ),
  );
  const r = expandEvents(
    ics,
    ...range('2026-11-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  assert.deepEqual(
    r.map((e) => [new Date(e.start).toISOString().slice(0, 16), e.title]),
    [
      ['2026-11-02T08:00', 'Daily'],
      ['2026-11-04T14:00', 'Daily (moved)'],
      ['2026-11-05T08:00', 'Daily'],
    ],
  );
});

test('rrule: an occurrence moved into the window shows, one moved out of it does not', () => {
  const ics = cal(
    ev(
      'UID:w',
      'DTSTART:20261102T090000Z',
      'DTEND:20261102T100000Z',
      'RRULE:FREQ=WEEKLY',
      'SUMMARY:Weekly',
    ),
    ev(
      'UID:w',
      'RECURRENCE-ID:20261109T090000Z',
      'DTSTART:20261111T100000Z',
      'DTEND:20261111T110000Z',
      'SUMMARY:Moved in',
    ),
    ev(
      'UID:w',
      'RECURRENCE-ID:20261116T090000Z',
      'DTSTART:20261120T100000Z',
      'DTEND:20261120T110000Z',
      'SUMMARY:Moved out',
    ),
  );
  const r = expandEvents(
    ics,
    ...range('2026-11-10T00:00:00Z', '2026-11-17T00:00:00Z'),
  );
  assert.deepEqual(
    r.map((e) => [new Date(e.start).toISOString().slice(0, 16), e.title]),
    [['2026-11-11T10:00', 'Moved in']],
  );
});

test('rrule: YEARLY with BYMONTH and an ordinal BYDAY', () => {
  const r = expandEvents(
    cal(
      ev(
        'UID:y',
        'SUMMARY:Y',
        'DTSTART:20261101T100000Z',
        'RRULE:FREQ=YEARLY;BYMONTH=3,11;BYDAY=1SU',
      ),
    ),
    ...range('2026-10-01T00:00:00Z', '2028-01-01T00:00:00Z'),
  );
  assert.deepEqual(iso(r), [
    '2026-11-01T10:00',
    '2027-03-07T10:00',
    '2027-11-07T10:00',
  ]);
});

test('rrule: YEARLY BYMONTHDAY / BYDAY without BYMONTH cover every month', () => {
  const one = (start: string, rule: string, a: string, b: string) =>
    iso(
      expandEvents(
        cal(ev('UID:y', 'SUMMARY:Y', `DTSTART:${start}`, rule)),
        ...range(a, b),
      ),
    );
  assert.equal(
    one(
      '20260101T090000Z',
      'RRULE:FREQ=YEARLY;BYMONTHDAY=1',
      '2026-01-01T00:00:00Z',
      '2027-01-01T00:00:00Z',
    ).length,
    12,
  );
  const mondays = one(
    '20261102T090000Z',
    'RRULE:FREQ=YEARLY;BYDAY=MO',
    '2026-11-01T00:00:00Z',
    '2026-12-01T00:00:00Z',
  );
  assert.deepEqual(mondays, [
    '2026-11-02T09:00',
    '2026-11-09T09:00',
    '2026-11-16T09:00',
    '2026-11-23T09:00',
    '2026-11-30T09:00',
  ]);
  // Ordinal without BYMONTH: the nth weekday of the year.
  assert.deepEqual(
    one(
      '20270104T090000Z',
      'RRULE:FREQ=YEARLY;BYDAY=1MO',
      '2027-01-01T00:00:00Z',
      '2029-01-01T00:00:00Z',
    ),
    ['2027-01-04T09:00', '2028-01-03T09:00'],
  );
});

test('rrule: DTSTART is always the first instance and counts toward COUNT', () => {
  const one = (start: string, rule: string) =>
    iso(
      expandEvents(
        cal(ev('UID:d', 'SUMMARY:D', `DTSTART:${start}`, rule)),
        ...range('2026-11-01T00:00:00Z', '2026-12-31T00:00:00Z'),
      ),
    );
  // Tue 3 Nov does not match BYDAY=MO: still the first of the two.
  assert.deepEqual(
    one('20261103T090000Z', 'RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=2'),
    ['2026-11-03T09:00', '2026-11-09T09:00'],
  );
  assert.deepEqual(
    one('20261104T090000Z', 'RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2'),
    ['2026-11-04T09:00', '2026-11-09T09:00'],
  );
});

test('rrule: a VALARM inside the event does not change its SUMMARY or UID', () => {
  const ics = cal(
    ev(
      'BEGIN:VALARM',
      'ACTION:DISPLAY',
      'UID:alarm-uid',
      'SUMMARY:Alarm',
      'DESCRIPTION:Reminder',
      'TRIGGER:-PT15M',
      'END:VALARM',
      'UID:real',
      'SUMMARY:Real',
      'DTSTART:20261105T100000Z',
      'DTEND:20261105T110000Z',
    ),
  );
  const r = expandEvents(
    ics,
    ...range('2026-11-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  assert.deepEqual(
    r.map((e) => [e.id, e.title]),
    [['real', 'Real']],
  );
});

test('tz: Outlook quoted TZID with a colon, Windows names for CalDAV too', () => {
  const outlook = cal(
    ev(
      'UID:o',
      'SUMMARY:Outlook',
      'DTSTART;TZID="(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna":20261105T100000',
      'DTEND;TZID="(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna":20261105T110000',
    ),
  );
  const r = expandEvents(
    outlook,
    ...range('2026-11-01T00:00:00Z', '2026-12-01T00:00:00Z'),
  );
  assert.deepEqual(iso(r), ['2026-11-05T09:00']);
  assert.equal(r[0]!.end - r[0]!.start, 3_600_000);
  assert.equal(parseEvents(outlook)[0]!.start, Date.UTC(2026, 10, 5, 9));
  // CalDAV (parseEvents) with a Windows zone name.
  const win = parseEvents(
    cal(
      ev(
        'UID:w',
        'SUMMARY:Win',
        'DTSTART;TZID=W. Europe Standard Time:20261105T100000',
      ),
    ),
  );
  assert.equal(win[0]!.start, Date.UTC(2026, 10, 5, 9));
});

test('tz: wall-clock times on DST-change days', () => {
  // Berlin switches at 02:00 on 28 Mar 2027: 01:30 is still CET (UTC+1).
  assert.equal(
    zonedToEpoch(2027, 3, 28, 1, 30, 0, 'Europe/Berlin'),
    Date.UTC(2027, 2, 28, 0, 30),
  );
  // New York switches at 02:00 on 14 Mar 2027: 03:30 is EDT (UTC-4).
  assert.equal(
    zonedToEpoch(2027, 3, 14, 3, 30, 0, 'America/New_York'),
    Date.UTC(2027, 2, 14, 7, 30),
  );
  const weekly = (tz: string, start: string) =>
    iso(
      expandEvents(
        cal(
          ev(
            'UID:d',
            'SUMMARY:D',
            `DTSTART;TZID=${tz}:${start}`,
            'RRULE:FREQ=WEEKLY;COUNT=2',
          ),
        ),
        ...range('2027-03-01T00:00:00Z', '2027-04-01T00:00:00Z'),
      ),
    );
  assert.deepEqual(weekly('Europe/Berlin', '20270321T013000'), [
    '2027-03-21T00:30',
    '2027-03-28T00:30',
  ]);
  assert.deepEqual(weekly('America/New_York', '20270307T033000'), [
    '2027-03-07T08:30',
    '2027-03-14T07:30',
  ]);
});

test('ics account: plain http is refused (loopback allowed), so is a redirect to http', async () => {
  const { op, id, m } = await icsApp(
    () =>
      new Response(null, {
        status: 302,
        headers: { location: 'http://evil.example/cal.ics?k=SECRET' },
      }),
    [
      { u: 'localhost', res: () => new Response(FEED) },
      { u: 'evil.example', res: () => new Response(FEED) },
    ],
  );
  await op('accounts.set_credential', {
    id,
    key: 'url',
    value: 'http://cal.example/x.ics?k=SECRET',
  });
  const plain = (await op('accounts.check', { id })).result;
  assert.equal(plain.ok, false);
  assert.match(plain.error, /https/);
  assert.ok(!plain.error.includes('SECRET'), plain.error);
  assert.equal(m.seen.length, 0);

  await op('accounts.set_credential', {
    id,
    key: 'url',
    value: 'http://localhost:8080/cal.ics',
  });
  const local = (await op('accounts.check', { id })).result;
  assert.deepEqual([local.ok, local.detail], [true, '2 events']);

  await op('accounts.set_credential', { id, key: 'url', value: SECRET });
  const redir = (await op('accounts.check', { id })).result;
  assert.equal(redir.ok, false);
  assert.match(redir.error, /http/);
  assert.ok(!/evil|SECRET/.test(redir.error), redir.error);
  // The plain-http address is never requested, so the secret never travels unencrypted.
  assert.ok(!m.seen.some((s) => s.url.includes('evil.example')));
});

test('ics account: an https redirect is followed', async () => {
  const { op, id } = await icsApp(undefined, [
    {
      u: 'calendar.example/old',
      res: () =>
        new Response(null, {
          status: 301,
          headers: { location: 'https://outlook.office365.com/new.ics' },
        }),
    },
  ]);
  await op('accounts.set_credential', {
    id,
    key: 'url',
    value: 'https://calendar.example/old.ics',
  });
  const r = (await op('accounts.check', { id })).result;
  assert.equal(r.ok, true, r.error);
});

test('ics account: check says "1 event"', async () => {
  const { op, id } = await icsApp(
    () =>
      new Response(cal(ev('UID:1', 'SUMMARY:One', 'DTSTART:20261105T100000Z'))),
  );
  await op('accounts.set_credential', { id, key: 'url', value: SECRET });
  assert.equal((await op('accounts.check', { id })).result.detail, '1 event');
});

test('ics account: concurrent queries share one fetch; a failure is cached for 2 minutes', async () => {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const ok = await icsApp(async () => {
    await gate;
    return new Response(FEED);
  });
  await ok.op('accounts.set_credential', {
    id: ok.id,
    key: 'url',
    value: SECRET,
  });
  const from = Date.parse('2026-11-03T00:00:00Z');
  const c = ok.t.app.integrations.calendar!;
  const a = c.events(from, from + 86_400_000);
  const b = c.events(from, from + 86_400_000);
  await new Promise((r) => setImmediate(r));
  release();
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(ok.m.seen.length, 1);
  assert.equal(ra.length, 1);
  assert.deepEqual(ra, rb);

  const bad = await icsApp(() => new Response('x', { status: 500 }));
  await bad.op('accounts.set_credential', {
    id: bad.id,
    key: 'url',
    value: SECRET,
  });
  const bc = bad.t.app.integrations.calendar!;
  await assert.rejects(bc.events(from, from + 86_400_000), /HTTP 500/);
  await assert.rejects(bc.events(from, from + 86_400_000), /HTTP 500/);
  assert.equal(bad.m.seen.length, 1);
  bad.t.clock.advance(3 * 60_000);
  await assert.rejects(bc.events(from, from + 86_400_000), /HTTP 500/);
  assert.equal(bad.m.seen.length, 2);
  // An explicit check tries again at once.
  await bad.op('accounts.check', { id: bad.id });
  assert.equal(bad.m.seen.length, 3);
});

test('calendar: one slow account does not delay the others (queried in parallel, order kept)', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const op = async (n: string, i: unknown) =>
    (await t.app.ops.invoke(n, i, 'app')) as any;
  const a = (await op('accounts.add', { kind: 'ics', label: 'A' })).result.id;
  const b = (await op('accounts.add', { kind: 'ics', label: 'B' })).result.id;
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const started: string[] = [];
  const merged = new MergedCalendar(t.app, (_app, acc) => ({
    ...defaultBackend(t.app, acc),
    async events() {
      started.push(acc.label);
      if (acc.id === a) await gate;
      return [
        {
          id: acc.id,
          title: 'Same',
          start: Date.UTC(2026, 10, 5, 9),
          end: Date.UTC(2026, 10, 5, 10),
        },
      ];
    },
  }));
  const p = merged.events(Date.UTC(2026, 10, 5), Date.UTC(2026, 10, 6));
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(started, ['A', 'B']);
  release();
  // Same title + start in both: dedupe keeps the first account's.
  assert.deepEqual(
    (await p).map((e) => e.id),
    [a],
  );
  void b;
});

test('calendar: writeDefault on an ics account is ignored; create goes to the real calendar', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const op = async (n: string, i: unknown) =>
    (await t.app.ops.invoke(n, i, 'app')) as any;
  // The ics account comes first and claims writeDefault.
  const ics = (
    await op('accounts.add', {
      kind: 'ics',
      label: 'Work',
      config: { writeDefault: true },
    })
  ).result.id;
  const dav = (
    await op('accounts.add', {
      kind: 'caldav',
      label: 'Nextcloud',
      config: { url: 'https://caldav.example/', username: 'jan' },
    })
  ).result.id;
  const created: string[] = [];
  const merged = new MergedCalendar(t.app, (app, acc) =>
    acc.kind === 'ics'
      ? defaultBackend(app, acc)
      : {
          ...defaultBackend(app, acc),
          async create() {
            created.push(acc.id);
            return 'new';
          },
        },
  );
  const r = await merged.createEvent({
    title: 'x',
    start: '2026-11-05T10:00:00Z',
    end: '2026-11-05T11:00:00Z',
  });
  assert.equal(r.ok, true, r.text);
  assert.deepEqual(created, [dav]);
  assert.match(r.text, /Nextcloud/);
  void ics;
});
