import assert from 'node:assert/strict';
import { test } from 'node:test';
import { newRun } from './tools/registry.ts';
import { jsonResponse, makeApp } from './testing/helpers.ts';

const run = (t: ReturnType<typeof makeApp>, name: string, args: unknown) =>
  t.app.tools.call(name, args, { app: t.app, run: newRun() });

test('shell: runs in workspace, minimal env, logged', async () => {
  process.env.SECRET_FOR_TEST = 'leak-me';
  const t = makeApp();
  const r = await run(t, 'shell', {
    command: 'pwd; echo "$SECRET_FOR_TEST|$MASTER_KEY|$HOME"; printenv PATH',
  });
  assert.ok(r.ok);
  assert.ok(
    r.text.includes(t.app.config.workspaceDir.replace(/^\/private/, '')) ||
      r.text.includes('workspace'),
  );
  assert.ok(!r.text.includes('leak-me'));
  assert.ok(!r.text.includes('test-master-key'));
  assert.match(r.text, /\[exit code 0\]/);
  const log = t.app.db.all<{ command: string; exit_code: number }>(
    'SELECT * FROM shell_log',
  );
  assert.equal(log.length, 1);
  assert.equal(log[0]!.exit_code, 0);
});

test('shell: output cap', async () => {
  const t = makeApp();
  t.app.settings.set('shell.max_output_chars', 100);
  const r = await run(t, 'shell', { command: 'yes abcdefghij | head -c 5000' });
  assert.match(r.text, /output truncated at 100/);
  assert.ok(r.text.length < 300);
  assert.equal(
    t.app.db.get<{ truncated: number }>('SELECT truncated FROM shell_log')!
      .truncated,
    1,
  );
});

test('shell: timeout kills the process group', async () => {
  const t = makeApp();
  t.app.settings.set('shell.timeout_sec', 1);
  const t0 = Date.now();
  const r = await run(t, 'shell', { command: 'sleep 30 & sleep 30' });
  assert.ok(Date.now() - t0 < 5000);
  assert.match(r.text, /timed out after 1 s/);
  assert.equal(
    t.app.db.get<{ timed_out: number }>('SELECT timed_out FROM shell_log')!
      .timed_out,
    1,
  );
});

test('shell: can be disabled by the safety setting; scripts on PATH mark use', async () => {
  const t = makeApp();
  t.app.skills.put('script', 'hello.sh', '#!/bin/sh\necho hi-from-script\n');
  const r = await run(t, 'shell', { command: 'hello.sh' });
  assert.match(r.text, /hi-from-script/);
  assert.equal(t.app.skills.list('script')[0]!.useCount, 1);
  t.app.settings.set('shell.enabled', false);
  assert.match(
    (await run(t, 'shell', { command: 'echo x' })).text,
    /turned off/,
  );
});

const forecast = {
  hourly: {
    time: Array.from(
      { length: 24 },
      (_, h) => `2026-11-03T${String(h).padStart(2, '0')}:00`,
    ),
    temperature_2m: Array.from({ length: 24 }, (_, h) => 5 + h / 4),
    apparent_temperature: Array.from({ length: 24 }, () => 3),
    precipitation_probability: Array.from({ length: 24 }, () => 40),
    precipitation: Array.from({ length: 24 }, () => 0.2),
    weather_code: Array.from({ length: 24 }, () => 61),
    wind_speed_10m: Array.from({ length: 24 }, () => 12),
  },
  daily: {
    time: ['2026-11-04', '2026-11-05'],
    weather_code: [0, 63],
    temperature_2m_max: [10, 8],
    temperature_2m_min: [3, 2],
    precipitation_sum: [0, 5.5],
    precipitation_probability_max: [5, 90],
    wind_speed_10m_max: [20, 30],
  },
};

test('weather: no default location -> tells the model to call location', async () => {
  const t = makeApp();
  const r = await run(t, 'weather', {});
  assert.match(r.text, /Call the `location` tool first/);
  assert.equal(t.fetchCalls.length, 0);
});

test('weather: geocodes a place and returns hourly range', async () => {
  const t = makeApp({
    fetch: async (u) => {
      const url = String(u);
      if (url.includes('geocoding-api'))
        return jsonResponse({
          results: [
            {
              name: 'Hamburg',
              country: 'Germany',
              admin1: 'Hamburg',
              latitude: 53.55,
              longitude: 10,
            },
          ],
        });
      return jsonResponse(forecast);
    },
  });
  const r = await run(t, 'weather', {
    place: 'Hamburg',
    from: '09:00',
    to: '12:00',
  });
  assert.ok(r.ok);
  assert.match(
    r.text,
    /Hourly forecast for Hamburg, Hamburg, Germany on 2026-11-03/,
  );
  assert.match(r.text, /09:00 light rain/);
  assert.match(r.text, /12:00 light rain/);
  assert.ok(!/13:00/.test(r.text));
  assert.ok(t.fetchCalls[0]!.includes('name=Hamburg'));
  assert.ok(
    t.fetchCalls[1]!.includes('latitude=53.55') &&
      t.fetchCalls[1]!.includes('start_date=2026-11-03&end_date=2026-11-03'),
  );
});

test('weather: lat/lon skip geocoding; days gives daily forecast', async () => {
  const t = makeApp({ fetch: async () => jsonResponse(forecast) });
  const r = await run(t, 'weather', {
    lat: 53.5,
    lon: 10,
    date: '2026-11-04',
    days: 2,
  });
  assert.match(r.text, /Daily forecast/);
  assert.match(r.text, /2026-11-05: rain, 2\.\.8 °C/);
  assert.equal(t.fetchCalls.length, 1);
  assert.ok(
    t.fetchCalls[0]!.includes('daily=') &&
      t.fetchCalls[0]!.includes('start_date=2026-11-04&end_date=2026-11-05'),
  );
});

test('weather: validates dates, unknown places and bad ranges', async () => {
  const t = makeApp({ fetch: async () => jsonResponse({ results: [] }) });
  assert.match(
    (await run(t, 'weather', { place: 'Nirgendwo' })).text,
    /Place not found/,
  );
  assert.match(
    (await run(t, 'weather', { lat: 1, lon: 1, date: '2027-02-01' })).text,
    /outside the forecast range/,
  );
  assert.match(
    (await run(t, 'weather', { lat: 1, lon: 1, from: '25:00' })).text,
    /Invalid arguments/,
  );
  assert.match(
    (await run(t, 'weather', { lat: 1, lon: 1, days: 40 })).text,
    /Invalid arguments/,
  );
});

test('web_fetch: strips html, blocks private hosts, honours the setting', async () => {
  const t = makeApp({
    fetch: async () =>
      new Response(
        '<html><script>x()</script><h1>Titel</h1><p>Hallo &amp; Welt</p></html>',
        { headers: { 'content-type': 'text/html' } },
      ),
  });
  const r = await run(t, 'web_fetch', { url: 'https://example.com/a' });
  assert.match(r.text, /Titel/);
  assert.match(r.text, /Hallo & Welt/);
  assert.ok(!r.text.includes('x()'));
  assert.match(
    (await run(t, 'web_fetch', { url: 'http://169.254.169.254/latest' })).text,
    /blocked/,
  );
  assert.match(
    (await run(t, 'web_fetch', { url: 'http://localhost:8787/' })).text,
    /blocked/,
  );
  t.app.settings.set('web_fetch.enabled', false);
  assert.match(
    (await run(t, 'web_fetch', { url: 'https://example.com' })).text,
    /turned off/,
  );
});

test('web_fetch SSRF: mapped IPv6, CGNAT, literal forms, DNS answers and redirects are all checked', async () => {
  const { isPrivateAddress } = await import('./tools/web.ts');
  for (const ip of [
    '127.0.0.1',
    '10.1.2.3',
    '100.64.0.7',
    '100.127.255.255',
    '169.254.169.254',
    '172.16.0.1',
    '192.168.1.1',
    '0.0.0.0',
    '224.0.0.1',
    '255.255.255.255',
    '::',
    '::1',
    'fc00::1',
    'fd12:3456::1',
    'fe80::1',
    'ff02::1',
    '::ffff:127.0.0.1',
    '::ffff:7f00:1',
    '::ffff:a9fe:a9fe',
    '::127.0.0.1',
    '[::1]',
  ])
    assert.equal(isPrivateAddress(ip), true, ip);
  for (const ip of [
    '::ffff:0:127.0.0.1',
    '64:ff9b:1::1',
    'fec0::1',
    '2001:0:4136:e378::1',
  ])
    assert.equal(isPrivateAddress(ip), true, ip);
  for (const ip of [
    '8.8.8.8',
    '100.128.0.1',
    '172.32.0.1',
    '2606:4700::1111',
    '::ffff:8.8.8.8',
  ])
    assert.equal(isPrivateAddress(ip), false, ip);

  const hits: string[] = [];
  const t = makeApp({
    fetch: async (u: any) => {
      hits.push(String(u));
      const url = new URL(String(u));
      if (url.pathname === '/to-local')
        return new Response('', {
          status: 302,
          headers: { location: 'http://127.0.0.1:8787/api/v1/pair/code' },
        });
      if (url.pathname === '/hop')
        return new Response('', {
          status: 301,
          headers: { location: '/final' },
        });
      if (url.pathname === '/loop')
        return new Response('', {
          status: 302,
          headers: { location: '/loop' },
        });
      return new Response('x'.repeat(100_000), {
        headers: { 'content-type': 'text/plain' },
      });
    },
  });
  const blocked = async (url: string) =>
    assert.match((await run(t, 'web_fetch', { url })).text, /blocked/, url);
  await blocked('http://[::ffff:7f00:1]/');
  await blocked('http://[::ffff:127.0.0.1]/');
  await blocked('http://2130706433/'); // decimal 127.0.0.1
  await blocked('http://0x7f.1/');
  await blocked('http://100.64.1.1/'); // CGNAT
  t.setLookup(async (h) =>
    h === 'evil.example' ? ['8.8.8.8', '10.0.0.5'] : ['93.184.215.14'],
  );
  await blocked('https://evil.example/'); // ANY private answer blocks
  assert.equal(hits.length, 0, 'nothing was fetched');

  await blocked('https://example.com/to-local');
  assert.deepEqual(
    hits,
    ['https://example.com/to-local'],
    'redirect target not fetched',
  );
  hits.length = 0;
  const ok = await run(t, 'web_fetch', {
    url: 'https://example.com/hop',
    maxChars: 500,
  });
  assert.match(ok.text, /^HTTP 200/);
  assert.match(ok.text, /truncated at 500/);
  assert.deepEqual(hits, [
    'https://example.com/hop',
    'https://example.com/final',
  ]);
  assert.match(
    (await run(t, 'web_fetch', { url: 'https://example.com/loop' })).text,
    /Too many redirects/,
  );
});

test('web_fetch caps the download (4 MB) and the returned text (maxChars)', async () => {
  let pulled = 0;
  const t = makeApp({
    fetch: async () =>
      new Response(
        new ReadableStream({
          pull(c) {
            pulled += 1000;
            if (pulled > 50_000_000) c.close();
            else c.enqueue(new TextEncoder().encode('y'.repeat(1000)));
          },
        }),
        { headers: { 'content-type': 'text/plain' } },
      ),
  });
  const r = await run(t, 'web_fetch', {
    url: 'https://example.com/big',
    maxChars: 1000,
  });
  assert.match(r.text, /truncated at 1000/);
  assert.ok(pulled <= 4_100_000, `pulled ${pulled} bytes`);
});

test('phone action proposals use exactly the phone tool schemas (apps/ios/Lotti/PhoneTools.swift)', async () => {
  const t = makeApp();
  const params = (name: string) => {
    const spec = t.app.tools.specs([t.app.tools.get(name)!])[0]!
      .parameters as any;
    return {
      props: Object.fromEntries(
        Object.entries(spec.properties).map(([k, v]: [string, any]) => [
          k,
          {
            type: v.type,
            ...(v.enum ? { enum: v.enum } : {}),
            ...(v.minimum !== undefined
              ? { min: v.minimum, max: v.maximum }
              : {}),
          },
        ]),
      ),
      required: spec.required ?? [],
    };
  };
  assert.deepEqual(params('set_timer'), {
    props: {
      minutes: { type: 'integer', min: 1, max: 720 },
      label: { type: 'string' },
    },
    required: ['minutes'],
  });
  assert.deepEqual(params('create_reminder'), {
    props: { text: { type: 'string' }, due: { type: 'string' } },
    required: ['text'],
  });
  assert.match(
    (
      t.app.tools.specs([t.app.tools.get('create_reminder')!])[0]!
        .parameters as any
    ).properties.due.description,
    /tomorrow 09:00/,
  );
  assert.deepEqual(params('start_navigation'), {
    props: {
      destination: { type: 'string' },
      mode: { type: 'string', enum: ['walk', 'bike'] },
    },
    required: ['destination'],
  });
  assert.match(
    (await run(t, 'set_timer', { minutes: 0.5 })).text,
    /Invalid arguments/,
  );
  assert.match(
    (await run(t, 'set_timer', { minutes: 721 })).text,
    /Invalid arguments/,
  );
  assert.match(
    (await run(t, 'start_navigation', { destination: 'x', mode: 'driving' }))
      .text,
    /Invalid arguments/,
  );
});

test('confirmation titles name what runs: mail recipient + body, calendar time + attendees', async () => {
  const t = makeApp();
  await run(t, 'send_mail_reply', {
    mailId: 'm1',
    to: 'boss@example.com',
    body: 'Ja,   passt mir.\nBis morgen',
  });
  await t.app.tools.call(
    'create_calendar_event',
    {
      title: 'Zahnarzt',
      start: '2026-11-04T10:00:00+01:00',
      end: '2026-11-04T11:00:00+01:00',
      attendees: ['a@example.com'],
    },
    { app: t.app, run: newRun({ utcOffsetMin: 60 }) },
  );
  await t.app.tools.call(
    'delete_calendar_event',
    { eventRef: 'a|b|c', title: 'Standup', start: '2026-11-04T10:00:00+01:00' },
    { app: t.app, run: newRun({ utcOffsetMin: 60, locale: 'de' }) },
  );
  const titles = t.app.db
    .all<{ title: string }>('SELECT title FROM actions ORDER BY rowid')
    .map((r) => r.title);
  assert.equal(
    titles[0],
    'Send reply to boss@example.com: "Ja, passt mir. Bis morgen"',
  );
  assert.equal(
    titles[1],
    'Add "Zahnarzt" · Wed 4 Nov 10:00–11:00 with a@example.com',
  );
  assert.ok(!/\d{4}-\d\d-\d\dT/.test(titles[1]!), 'no raw ISO timestamps');
  assert.match(titles[2]!, /^Delete "Standup" · .*10:00$/);
  await run(t, 'send_mail_reply', { mailId: 'm1', body: 'x'.repeat(500) });
  const long = t.app.db.all<{ title: string }>(
    'SELECT title FROM actions ORDER BY rowid DESC LIMIT 1',
  )[0]!.title;
  assert.ok(long.length <= 140, long);
});

test('phone tools without a phone say so; skill_load and conversation tools work', async () => {
  const t = makeApp();
  assert.match((await run(t, 'location', {})).text, /not connected/);
  assert.match((await run(t, 'reminders', {})).text, /not connected/);
  t.app.skills.put('skill', 'x', '# X\nbody');
  assert.equal((await run(t, 'skill_load', { name: 'x' })).text, '# X\nbody');
  assert.match((await run(t, 'skill_load', { name: 'nope' })).text, /No skill/);
  assert.equal(
    (await run(t, 'conversation_search', { query: 'nothing here' })).text,
    'No matches.',
  );
});

test('proposed server actions run only after perform; handlers are stubs until connectors exist', async () => {
  const t = makeApp();
  // the spy is in place before the proposal: proposing must not call it
  let created: unknown;
  t.app.integrations.calendar = {
    events: async () => [],
    createEvent: async (a) => ((created = a), { ok: true, text: 'Angelegt' }),
  };
  const r = await run(t, 'create_calendar_event', {
    title: 'Zahnarzt',
    start: '2026-11-04T10:00:00+01:00',
    end: '2026-11-04T11:00:00+01:00',
  });
  assert.ok(r.ok);
  const action = t.app.db.get<{ id: string; status: string }>(
    'SELECT * FROM actions',
  )!;
  assert.equal(action.status, 'proposed');
  assert.equal(created, undefined); // nothing ran on proposal
  const p = await t.app.actions.perform(action.id);
  assert.deepEqual([p.ok, p.text], [true, 'Angelegt']);
  assert.equal((created as any).title, 'Zahnarzt');
  assert.equal((await t.app.actions.perform(action.id)).ok, false); // single use
  const m = await run(t, 'send_mail_reply', { mailId: '1', body: 'Danke' });
  const mid = t.app.db.get<{ id: string }>(
    "SELECT id FROM actions WHERE tool='send_mail_reply'",
  )!.id;
  assert.ok(m.ok);
  assert.match((await t.app.actions.perform(mid)).text, /No mail account/);
});
