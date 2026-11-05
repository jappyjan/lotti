import assert from 'node:assert/strict';
import { test } from 'node:test';
import { makeApp } from '../testing/helpers.ts';
import { newRun } from '../tools/registry.ts';
import { buildEvent, parseEvents } from './calendar/ics.ts';
import { eventRef } from './calendar/source.ts';
import { builtinJobs } from '../scheduler/builtin.ts';
import { connectGoogle, googleApp, mockFetch } from './testing.ts';
import { registerIntegrations } from './register.ts';

const ics = (body: string) =>
  `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${body}\r\nEND:VCALENDAR\r\n`;

test('ics: utc, TZID, all-day, folded lines, escapes, cancelled skipped', () => {
  const ev = parseEvents(
    ics(
      [
        'BEGIN:VEVENT',
        'UID:a1',
        'DTSTART:20261103T090000Z',
        'DTEND:20261103T100000Z',
        'SUMMARY:Stand\\, up',
        'LOCATION:Raum 1',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:a2',
        'DTSTART;TZID=Europe/Berlin:20261103T090000',
        'DTEND;TZID=Europe/Berlin:20261103T100000',
        'SUMMARY:Lang',
        ' er Titel',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:a3',
        'DTSTART;VALUE=DATE:20261104',
        'SUMMARY:Urlaub',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:a4',
        'DTSTART:20261105T090000Z',
        'STATUS:CANCELLED',
        'END:VEVENT',
      ].join('\r\n'),
    ),
    'Work',
  );
  assert.equal(ev.length, 3);
  assert.equal(ev[0]!.title, 'Stand, up');
  assert.equal(ev[0]!.start, Date.UTC(2026, 10, 3, 9));
  assert.equal(ev[0]!.location, 'Raum 1');
  assert.equal(ev[1]!.title, 'Langer Titel');
  assert.equal(ev[1]!.start, Date.UTC(2026, 10, 3, 8)); // Berlin is UTC+1 in November
  assert.equal(ev[2]!.allDay, true);
  assert.equal(ev[2]!.end - ev[2]!.start, 86_400_000);
  assert.equal(ev[0]!.calendar, 'Work');
  const b = buildEvent(0, {
    title: 'A;B',
    start: Date.UTC(2026, 10, 3, 9),
    end: Date.UTC(2026, 10, 3, 10),
  });
  assert.match(b.ics, /DTSTART:20261103T090000Z/);
  assert.match(b.ics, /SUMMARY:A\;B/);
  assert.equal(parseEvents(b.ics)[0]!.title, 'A;B');
});

const multistatus = (inner: string) =>
  new Response(
    `<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">${inner}</d:multistatus>`,
    { status: 207 },
  );

function davRoutes(events: string) {
  return [
    {
      m: 'PROPFIND',
      u: /^https:\/\/caldav\.example\/$/,
      res: () =>
        multistatus(
          '<d:response><d:href>/</d:href><d:propstat><d:prop><d:current-user-principal><d:href>/p/123/</d:href></d:current-user-principal></d:prop></d:propstat></d:response>',
        ),
    },
    {
      m: 'PROPFIND',
      u: '/p/123/',
      res: () =>
        multistatus(
          '<d:response><d:propstat><d:prop><c:calendar-home-set><d:href>/home/123/</d:href></c:calendar-home-set></d:prop></d:propstat></d:response>',
        ),
    },
    {
      m: 'PROPFIND',
      u: '/home/123/',
      res: () =>
        multistatus(
          '<d:response><d:href>/home/123/work/</d:href><d:propstat><d:prop><d:displayname>Work</d:displayname><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set></d:prop></d:propstat></d:response>' +
            '<d:response><d:href>/home/123/tasks/</d:href><d:propstat><d:prop><d:displayname>Tasks</d:displayname><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set></d:prop></d:propstat></d:response>' +
            '<d:response><d:href>/home/123/inbox/</d:href><d:propstat><d:prop><d:displayname>Inbox</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>',
        ),
    },
    {
      m: 'REPORT',
      u: '/home/123/work/',
      res: () =>
        multistatus(
          `<d:response><d:href>/home/123/work/x.ics</d:href><d:propstat><d:prop><c:calendar-data><![CDATA[${events}]]></c:calendar-data></d:prop></d:propstat></d:response>`,
        ),
    },
    {
      m: 'PUT',
      u: '/home/123/work/',
      res: () => new Response('', { status: 201 }),
    },
  ];
}

async function caldavApp() {
  const soon = new Date(2026, 10, 3, 8, 5);
  const fmt = (d: Date) =>
    d.toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
  const m = mockFetch(
    davRoutes(
      ics(
        `BEGIN:VEVENT\r\nUID:e1\r\nDTSTART:${fmt(soon)}\r\nDTEND:${fmt(new Date(+soon + 3600_000))}\r\nSUMMARY:Zahnarzt\r\nLOCATION:Praxis\r\nEND:VEVENT`,
      ),
    ),
  );
  const t = makeApp({ fetch: m.fetch });
  registerIntegrations(t.app);
  const id = (
    (await t.app.ops.invoke(
      'accounts.add',
      {
        kind: 'caldav',
        label: 'Nextcloud',
        config: { url: 'https://caldav.example/', username: 'jan' },
      },
      'app',
    )) as any
  ).result.id;
  await t.app.ops.invoke(
    'accounts.set_credential',
    { id, key: 'password', value: 'secret' },
    'app',
  );
  return { t, m, id };
}

test('caldav: discovery, calendar listing (only VEVENT calendars), expanded events, basic auth', async () => {
  const { t, m, id } = await caldavApp();
  const cals = (await t.app.ops.invoke(
    'accounts.calendars',
    { id },
    'app',
  )) as any;
  assert.deepEqual(cals.result, [
    {
      id: 'https://caldav.example/home/123/work/',
      name: 'Work',
      selected: true,
    },
  ]);
  assert.equal(
    m.seen[0]!.headers.authorization,
    'Basic ' + Buffer.from('jan:secret').toString('base64'),
  );
  const evs = await t.app.integrations.calendar!.events(
    t.clock.now(),
    t.clock.now() + 3600_000,
  );
  assert.equal(evs.length, 1);
  assert.equal(evs[0]!.title, 'Zahnarzt');
  assert.equal(evs[0]!.location, 'Praxis');
  const report = m.seen.find((s) => s.method === 'REPORT')!;
  assert.match(report.body, /c:expand/);
  assert.equal(
    ((await t.app.ops.invoke('accounts.check', { id }, 'app')) as any).result
      .ok,
    true,
  );
  const acc = ((await t.app.ops.invoke('accounts.list', {}, 'app')) as any)
    .result[0];
  assert.ok(acc.lastSyncAt > 0);
  assert.equal(acc.status, 'ok');
});

test('caldav: wrong password is reported on the account', async () => {
  const t = makeApp({ fetch: async () => new Response('', { status: 401 }) });
  registerIntegrations(t.app);
  const id = (
    (await t.app.ops.invoke(
      'accounts.add',
      { kind: 'icloud', label: 'iCloud', config: { username: 'a@icloud.com' } },
      'app',
    )) as any
  ).result.id;
  await t.app.ops.invoke(
    'accounts.set_credential',
    { id, key: 'password', value: 'x' },
    'app',
  );
  const r = (await t.app.ops.invoke('accounts.check', { id }, 'app')) as any;
  assert.equal(r.result.ok, false);
  assert.match(r.result.error, /login failed/);
  await assert.rejects(
    t.app.integrations.calendar!.events(0, 1),
    /login failed/,
  );
  const acc = ((await t.app.ops.invoke('accounts.list', {}, 'app')) as any)
    .result[0];
  assert.equal(acc.status, 'error');
});

test('caldav: create_calendar_event runs PUT only after perform', async () => {
  const { t, m } = await caldavApp();
  const run = newRun();
  const r = await t.app.tools.call(
    'create_calendar_event',
    {
      title: 'Kino',
      start: '2026-11-05T20:00:00+01:00',
      end: '2026-11-05T22:00:00+01:00',
      location: 'Cinema',
    },
    { app: t.app, run },
  );
  assert.match(r.text, /Proposed/);
  assert.ok(!m.seen.some((s) => s.method === 'PUT'));
  const out = await t.app.actions.perform(run.actions[0]!.id);
  assert.ok(out.ok, out.text);
  const put = m.seen.find((s) => s.method === 'PUT')!;
  assert.match(put.url, /\/home\/123\/work\/.+\.ics$/);
  assert.equal(put.headers['if-none-match'], '*');
  assert.match(put.body, /SUMMARY:Kino/);
  assert.match(put.body, /DTSTART:20261105T190000Z/);
  assert.equal((await t.app.actions.perform(run.actions[0]!.id)).ok, false); // once
});

test('ics: an alarm inside the event does not lend it its UID or summary (iCloud)', async () => {
  const { seriesInfo } = await import('./calendar/ics.ts');
  const data = ics(
    [
      'BEGIN:VEVENT',
      'UID:evt-1',
      'DTSTART:20261103T090000Z',
      'DTEND:20261103T100000Z',
      'SUMMARY:Zahnarzt',
      'BEGIN:VALARM',
      'UID:al-9',
      'ACTION:EMAIL',
      'SUMMARY:Reminder mail',
      'TRIGGER:-PT15M',
      'END:VALARM',
      'END:VEVENT',
    ].join('\r\n'),
  );
  const [ev] = parseEvents(data);
  assert.equal(ev!.id, 'evt-1');
  assert.equal(ev!.title, 'Zahnarzt');
  assert.deepEqual(seriesInfo(data), { uids: ['evt-1'], repeats: false });
});

// What Apple, Nextcloud and Thunderbird put in front of an event with a time zone: its daylight-saving
// rules are RRULEs too, but they don't make the event repeat.
const BERLIN = [
  'BEGIN:VTIMEZONE',
  'TZID:Europe/Berlin',
  'BEGIN:DAYLIGHT',
  'TZOFFSETFROM:+0100',
  'TZOFFSETTO:+0200',
  'DTSTART:19700329T020000',
  'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU',
  'END:DAYLIGHT',
  'BEGIN:STANDARD',
  'TZOFFSETFROM:+0200',
  'TZOFFSETTO:+0100',
  'DTSTART:19701025T030000',
  'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU',
  'END:STANDARD',
  'END:VTIMEZONE',
].join('\r\n');

test('caldav: delete_calendar_event removes a single event by UID, only after perform', async () => {
  const deleted: { url: string; ifMatch?: string }[] = [];
  const soon = new Date(2026, 10, 3, 9, 5);
  const fmt = (d: Date) =>
    d.toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
  const event = (extra = '') =>
    ics(
      `${BERLIN}\r\nBEGIN:VEVENT\r\nUID:e1\r\nDTSTART:${fmt(soon)}\r\nDTEND:${fmt(new Date(+soon + 3_600_000))}\r\nSUMMARY:Zahnarzt\r\n${extra}END:VEVENT`,
    );
  let stored = event();
  const m = mockFetch([
    {
      m: 'REPORT',
      u: '/home/123/work/',
      res: (r) =>
        multistatus(
          `<d:response><d:href>/home/123/work/x.ics</d:href><d:propstat><d:prop><d:getetag>"v1"</d:getetag><c:calendar-data><![CDATA[${stored}]]></c:calendar-data></d:prop></d:propstat></d:response>` +
            // the UID text-match is a substring match: a sibling whose UID merely contains "e1" comes back too
            (r.body.includes('text-match')
              ? `<d:response><d:href>/home/123/work/y.ics</d:href><d:propstat><d:prop><c:calendar-data><![CDATA[${stored.replace('UID:e1', 'UID:e1-copy')}]]></c:calendar-data></d:prop></d:propstat></d:response>`
              : ''),
        ),
    },
    ...davRoutes(stored),
    {
      m: 'DELETE',
      u: '/home/123/work/x.ics',
      res: (r) => (
        deleted.push({ url: r.url, ifMatch: r.headers['if-match'] }),
        new Response(null, { status: 204 })
      ),
    },
  ]);
  const t = makeApp({ fetch: m.fetch });
  registerIntegrations(t.app);
  const id = (
    (await t.app.ops.invoke(
      'accounts.add',
      {
        kind: 'caldav',
        label: 'N',
        config: { url: 'https://caldav.example/', username: 'jan' },
      },
      'app',
    )) as any
  ).result.id;
  await t.app.ops.invoke(
    'accounts.set_credential',
    { id, key: 'password', value: 'secret' },
    'app',
  );
  const cal = t.app.integrations.calendar!;
  const [ev] = await cal.events(t.clock.now(), t.clock.now() + 3_600_000 * 24);
  assert.ok(ev!.ref, 'events carry a reference');
  assert.ok(!ev!.ref!.includes('%2F'), 'the calendar URL stays readable');
  const listing = await t.app.tools.call(
    'calendar_events',
    {},
    { app: t.app, run: newRun() },
  );
  assert.ok(listing.text.includes(`{id: ${ev!.ref}}`), listing.text);
  assert.ok(!listing.text.includes('(repeats)'), 'a time zone is no repeat');

  // the card names the event the calendar has, whatever title the model passes
  const run = newRun({ utcOffsetMin: -new Date(soon).getTimezoneOffset() });
  await t.app.tools.call(
    'delete_calendar_event',
    { eventRef: ev!.ref, title: 'Something else' },
    { app: t.app, run },
  );
  assert.equal(run.actions.length, 1);
  assert.match(
    run.actions[0]!.title,
    /^Delete "Zahnarzt" · Tue 3 Nov 09:05–10:05$/,
  );
  assert.equal(run.actions[0]!.args?.title, 'Zahnarzt');
  assert.deepEqual(deleted, [], 'nothing deleted before the tap');
  const out = await t.app.actions.perform(run.actions[0]!.id);
  assert.ok(out.ok, out.text);
  assert.deepEqual(deleted, [
    { url: 'https://caldav.example/home/123/work/x.ics', ifMatch: '"v1"' },
  ]);

  // a repeating series is refused when proposed, so no card asks for a tap that cannot work
  deleted.length = 0;
  for (const extra of ['RRULE:FREQ=WEEKLY\r\n', 'RDATE:20261110T080500Z\r\n']) {
    stored = event(extra);
    const r2 = newRun();
    const said = await t.app.tools.call(
      'delete_calendar_event',
      { eventRef: ev!.ref },
      { app: t.app, run: r2 },
    );
    assert.match(said.text, /repeats/);
    assert.equal(r2.actions.length, 0);
  }
  // one occurrence of an expanded series (uid#recurrence-id) is refused without asking the server
  const before = m.seen.length;
  const r3 = newRun();
  const occ = await t.app.tools.call(
    'delete_calendar_event',
    { eventRef: ev!.ref!.replace(/e1$/, 'e1#20261103T080500Z') },
    { app: t.app, run: r3 },
  );
  assert.match(occ.text, /repeats/);
  assert.equal(r3.actions.length, 0);
  assert.equal(m.seen.length, before);

  // ... and when it became a series between the proposal and the tap
  stored = event();
  const r4 = newRun();
  await t.app.tools.call(
    'delete_calendar_event',
    { eventRef: ev!.ref },
    { app: t.app, run: r4 },
  );
  stored = event('RRULE:FREQ=WEEKLY\r\n');
  const refused = await t.app.actions.perform(r4.actions[0]!.id);
  assert.equal(refused.ok, false);
  assert.match(refused.text, /repeats/);
  assert.deepEqual(deleted, []);
  assert.equal(
    (await cal.deleteEvent!({ eventRef: 'garbage', title: 'x' })).ok,
    false,
  );
  assert.equal(
    (await cal.deleteEvent!({ eventRef: 'a|%E0%A4%A|c', title: 'x' })).ok,
    false,
    'a malformed escape is refused, not thrown',
  );
});

test('google calendar: delete removes the single occurrence by event id, never a series', async () => {
  const start = new Date(2026, 10, 3, 8, 5);
  const occurrence = {
    id: 'wk_20261103T080500Z',
    recurringEventId: 'wk',
    summary: 'Standup',
    start: { dateTime: start.toISOString() },
    end: { dateTime: new Date(+start + 1_800_000).toISOString() },
  };
  const { t, m } = googleApp([
    {
      m: 'GET',
      u: /\/calendars\/primary\/events\/wk_20261103T080500Z$/,
      res: () => occurrence,
    },
    {
      m: 'GET',
      u: /\/calendars\/primary\/events\/wk$/,
      res: () => ({
        ...occurrence,
        id: 'wk',
        recurringEventId: undefined,
        recurrence: ['RRULE:FREQ=WEEKLY'],
      }),
    },
    {
      m: 'GET',
      u: '/calendars/primary/events?',
      res: () => ({ items: [occurrence] }),
    },
    {
      m: 'DELETE',
      u: '/calendars/primary/events/',
      res: () => new Response(null, { status: 204 }),
    },
  ]);
  const acc = await connectGoogle(t);
  const [ev] = await t.app.integrations.calendar!.events(
    t.clock.now(),
    t.clock.now() + 86_400_000,
  );
  assert.equal(ev!.recurring, true);
  const list = m.seen.find((s) => s.url.includes('/events?'))!;
  assert.match(list.url, /singleEvents=true/, 'occurrences have their own ids');
  const run = newRun();
  await t.app.tools.call(
    'delete_calendar_event',
    { eventRef: ev!.ref, title: 'Fake' },
    { app: t.app, run },
  );
  assert.match(run.actions[0]!.title, /^Delete "Standup" · /);
  assert.equal(run.actions[0]!.args?.occurrence, true);
  assert.ok(!m.seen.some((s) => s.method === 'DELETE'));
  const out = await t.app.actions.perform(run.actions[0]!.id);
  assert.ok(out.ok, out.text);
  const dels = m.seen.filter((s) => s.method === 'DELETE');
  assert.equal(dels.length, 1);
  assert.match(dels[0]!.url, /\/events\/wk_20261103T080500Z$/);

  // a hand-made ref to the series itself, or to a calendar Lotti doesn't use, gets no card
  for (const [ref, why] of [
    [eventRef(acc, 'primary', 'wk'), /whole repeating series/],
    [eventRef(acc, 'boss@example.com', 'x'), /does not use that calendar/],
  ] as const) {
    const r = newRun();
    const said = await t.app.tools.call(
      'delete_calendar_event',
      { eventRef: ref },
      { app: t.app, run: r },
    );
    assert.match(said.text, why);
    assert.equal(r.actions.length, 0);
  }
  // and the series is refused at perform time too
  const direct = await t.app.integrations.calendar!.deleteEvent!({
    eventRef: eventRef(acc, 'primary', 'wk'),
  });
  assert.equal(direct.ok, false);
  assert.equal(m.seen.filter((s) => s.method === 'DELETE').length, 1);
});

test('google calendar: events with selected calendars, insert on perform, merged + deduped', async () => {
  const { t, m } = googleApp([
    {
      u: '/calendarList',
      res: () => ({
        items: [
          { id: 'primary', summary: 'Jan' },
          { id: 'fam@group', summary: 'Familie' },
        ],
      }),
    },
    {
      m: 'GET',
      u: '/calendars/fam%40group/events',
      res: () => ({
        items: [
          {
            id: 'f1',
            summary: 'Zahnarzt',
            start: { dateTime: new Date(2026, 10, 3, 8, 5).toISOString() },
            end: { dateTime: new Date(2026, 10, 3, 9, 5).toISOString() },
          },
        ],
      }),
    },
    {
      m: 'GET',
      u: '/calendars/primary/events',
      res: () => ({
        items: [
          {
            id: 'p1',
            summary: 'Ganztag',
            start: { date: '2026-11-03' },
            end: { date: '2026-11-04' },
          },
          { id: 'p2', status: 'cancelled' },
        ],
      }),
    },
    {
      m: 'POST',
      u: '/calendars/fam%40group/events',
      res: () => ({ id: 'new1' }),
    },
  ]);
  const id = await connectGoogle(t);
  const cals = (await t.app.ops.invoke(
    'accounts.calendars',
    { id },
    'app',
  )) as any;
  assert.equal(cals.result.length, 2);
  await t.app.ops.invoke(
    'accounts.set_calendars',
    { id, calendars: ['fam@group'] },
    'app',
  );
  const evs = await t.app.integrations.calendar!.events(
    t.clock.now(),
    t.clock.now() + 86_400_000,
  );
  assert.deepEqual(
    evs.map((e) => e.title),
    ['Zahnarzt'],
  );
  assert.ok(!m.seen.some((s) => s.url.includes('/calendars/primary/events')));
  assert.equal(
    (await t.app.integrations.calendar!.next!(t.clock.now()))!.title,
    'Zahnarzt',
  );

  await t.app.ops.invoke(
    'accounts.set_calendars',
    { id, calendars: [] },
    'app',
  );
  const all = await t.app.integrations.calendar!.events(
    t.clock.now(),
    t.clock.now() + 86_400_000,
  );
  assert.equal(all.length, 1); // only primary: all-day event
  assert.equal(all[0]!.allDay, true);

  await t.app.ops.invoke(
    'accounts.set_calendars',
    { id, calendars: ['fam@group'] },
    'app',
  );
  const run = newRun();
  await t.app.tools.call(
    'create_calendar_event',
    {
      title: 'Kino',
      start: '2026-11-05T20:00:00+01:00',
      end: '2026-11-05T22:00:00+01:00',
      attendees: ['a@b.de'],
    },
    { app: t.app, run },
  );
  const o = await t.app.actions.perform(run.actions[0]!.id);
  assert.ok(o.ok, o.text);
  const post = m.seen.find(
    (s) => s.method === 'POST' && s.url.includes('/events'),
  )!;
  const body = JSON.parse(post.body);
  assert.equal(body.summary, 'Kino');
  assert.equal(body.start.dateTime, '2026-11-05T19:00:00.000Z');
  assert.deepEqual(body.attendees, [{ email: 'a@b.de' }]);
  assert.match(post.headers.authorization!, /^Bearer at/);
});

test('calendar: tool calendar_events and built-in meeting_soon use the merged source', async () => {
  const { t } = await caldavApp();
  const run = newRun();
  const r = await t.app.tools.call(
    'calendar_events',
    { days: 1 },
    { app: t.app, run },
  );
  assert.match(r.text, /Zahnarzt @ Praxis \[Work\]/);
  assert.match(
    (
      await t.app.tools.call(
        'calendar_events',
        { nextOnly: true },
        { app: t.app, run },
      )
    ).text,
    /Next event/,
  );
  const job = builtinJobs.find((j) => j.key === 'meeting_soon')!;
  assert.match(await job.run(t.app), /1 meeting/);
  assert.equal(
    t.app.inbox.list().filter((i) => i.kind === 'calendar').length,
    1,
  );
});

test('calendar: nothing connected', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  assert.deepEqual(await t.app.integrations.calendar!.events(0, 1e12), []);
  const o = await t.app.integrations.calendar!.createEvent!({
    title: 'x',
    start: '2026-11-05T20:00:00Z',
    end: '2026-11-05T21:00:00Z',
  });
  assert.equal(o.ok, false);
  assert.match(o.text, /No calendar/);
});

test('caldav: discovered calendars are cached for 1 h per account; an account edit invalidates', async () => {
  const { t, m, id } = await caldavApp();
  const propfinds = () => m.seen.filter((s) => s.method === 'PROPFIND').length;
  const cal = t.app.integrations.calendar!;
  await cal.events(t.clock.now(), t.clock.now() + 600_000);
  const first = propfinds();
  assert.ok(first >= 1);
  for (let i = 0; i < 5; i++) {
    t.clock.advanceMinutes(1);
    await cal.events(t.clock.now(), t.clock.now() + 600_000);
  }
  assert.equal(propfinds(), first, 'no discovery every minute');
  t.clock.advanceMinutes(61);
  await cal.events(t.clock.now(), t.clock.now() + 600_000);
  assert.equal(propfinds(), first * 2, 'rediscovered after an hour');
  await t.app.ops.invoke(
    'accounts.set_calendars',
    { id, calendars: ['https://caldav.example/home/123/work/'] },
    'app',
  );
  await cal.events(t.clock.now(), t.clock.now() + 600_000);
  assert.equal(propfinds(), first * 3, 'selection change invalidates');
});
