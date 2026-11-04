import assert from 'node:assert/strict';
import { test } from 'node:test';
import { makeApp } from '../testing/helpers.ts';
import { expandEvents } from './calendar/recur.ts';
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
  assert.deepEqual(
    expandEvents(
      ics,
      ...range('2026-11-01T00:00:00Z', '2026-11-30T00:00:00Z'),
    ).map((e) => e.title),
    ['In'],
  );
  assert.deepEqual(starts([]), []);
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

async function icsApp(res?: () => Response | unknown) {
  const m = mockFetch([
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
  assert.ok(ev.length > 0);
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
