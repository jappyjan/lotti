import assert from 'node:assert/strict';
import { test } from 'node:test';
import { nightOverlapMs } from './catchup.ts';
import { makeApp, text, type TestApp } from './testing/helpers.ts';

const at = (day: number, h: number, m = 0) => new Date(2026, 10, day, h, m);

async function ev(t: TestApp, event: string, when: Date) {
  t.clock.set(when);
  return t.app.catchup.onPresence(event, when.getTime());
}

function listen(t: TestApp) {
  const got: any[] = [];
  t.app.hub.add({
    id: 'c',
    deviceId: 'd',
    deviceName: 'd',
    ready: true,
    send: (m) => m.type === 'catchup' && got.push(m),
    close() {},
  });
  return got;
}

test('night overlap maths (22:00-09:00 wraps midnight)', () => {
  const o = (a: Date, b: Date) =>
    nightOverlapMs(a.getTime(), b.getTime(), '22:00', '09:00') / 3_600_000;
  assert.equal(o(at(3, 23), at(4, 7)), 8);
  assert.equal(o(at(3, 9), at(3, 22)), 0);
  assert.equal(o(at(3, 20), at(4, 10)), 11);
  assert.equal(o(at(3, 8), at(3, 12)), 1);
});

test('away >= 2 h (no presence) triggers one brief on return; <2 h does not', async () => {
  const t = makeApp({ toolTimeoutMs: 30 });
  const got = listen(t);
  t.mock.script(text('Zwei neue Mails, nächster Termin 14:00.'));
  assert.equal(
    (await ev(t, 'app_open', at(3, 8))).triggered,
    false,
    'first ever event: nothing to compare',
  );
  assert.equal(
    (await ev(t, 'gesture', at(3, 9, 30))).triggered,
    false,
    '1.5 h is not away',
  );
  assert.equal(
    (await ev(t, 'glasses_removed', at(3, 9, 40))).triggered,
    false,
    'removal is not a return',
  );
  const d = await ev(t, 'glasses_worn', at(3, 12, 0));
  assert.deepEqual([d.triggered, d.reason], [true, 'away']);
  assert.equal(got.length, 1);
  assert.equal(got[0].text, 'Zwei neue Mails, nächster Termin 14:00.');
  assert.match(got[0].at, /^2026-11-03T12:00:00[+-]\d\d:\d\d$/);
  assert.equal(t.app.catchup.recent()[0]!.text, got[0].text);
  // once per return
  assert.equal((await ev(t, 'head_up', at(3, 12, 1))).triggered, false);
  assert.equal((await ev(t, 'phone_unlock', at(3, 13, 0))).triggered, false);
  assert.equal(got.length, 1);
  // a new absence gives a new brief
  t.mock.script(text('Nachmittags-Brief'));
  assert.equal((await ev(t, 'phone_unlock', at(3, 15, 30))).triggered, true);
  assert.equal(got.length, 2);
});

test('slept: night with charging phone and no phone use, works without any wear events', async () => {
  const t = makeApp({ toolTimeoutMs: 30 });
  const got = listen(t);
  t.mock.script(text('Guten Morgen: 3 Termine heute.'));
  await ev(t, 'phone_unlock', at(3, 22, 40));
  await ev(t, 'phone_charging', at(3, 22, 45));
  await ev(t, 'phone_still', at(3, 22, 46));
  const d = await ev(t, 'head_up', at(4, 7, 15)); // just glasses motion, no worn/connected events
  assert.deepEqual([d.triggered, d.reason], [true, 'slept']);
  assert.equal(got.length, 1);
  assert.equal(
    (await ev(t, 'glasses_worn', at(4, 7, 30))).triggered,
    false,
    'once per return',
  );
  assert.equal((await ev(t, 'phone_unlock', at(4, 8, 0))).triggered, false);
});

test('slept needs the phone to be quiet and the night overlap; phone use at night breaks it', async () => {
  const t = makeApp({ toolTimeoutMs: 30 });
  const got = listen(t);
  // glasses worn for a long evening, no phone-quiet signal, then a short gap -> no slept (and < 2 h)
  await ev(t, 'phone_unlock', at(3, 22, 0));
  assert.equal((await ev(t, 'gesture', at(3, 23, 30))).triggered, false);
  assert.equal(got.length, 0);
  // phone used at 02:00, glasses at 07:00: gap 5 h -> reason is away, not slept
  const t2 = makeApp({ toolTimeoutMs: 30 });
  const got2 = listen(t2);
  t2.mock.script(text('Brief'));
  await ev(t2, 'phone_unlock', at(3, 22, 0));
  await ev(t2, 'phone_charging', at(3, 22, 5));
  await ev(t2, 'phone_unlock', at(3, 22, 30));
  await ev(t2, 'phone_charging', at(3, 22, 35));
  t2.mock.script(text('Brief 2'));
  await ev(t2, 'phone_unlock', at(4, 1, 30)); // woke up at night: away from 22:30..01:30 = 3 h -> brief
  const d = await ev(t2, 'head_up', at(4, 7, 0));
  assert.equal(d.triggered, true);
  assert.equal(d.reason, 'away'); // phone was used at 01:30, so the 5.5 h span is not "slept"... only away
  assert.ok(got2.length >= 1);
});

test('brief is nothing when the agent finds nothing relevant', async () => {
  const t = makeApp({ toolTimeoutMs: 30 });
  const got = listen(t);
  t.mock.script(text('NOTHING'));
  await ev(t, 'app_open', at(3, 8));
  const d = await ev(t, 'app_open', at(3, 12));
  assert.equal(d.triggered, true);
  assert.equal(got.length, 0);
  assert.equal(t.app.catchup.recent().length, 0);
});

test('settings are editable: disabled, custom away hours and night window', async () => {
  const t = makeApp({ toolTimeoutMs: 30 });
  const got = listen(t);
  t.app.settings.set('catchup.enabled', false);
  await ev(t, 'app_open', at(3, 8));
  assert.equal(
    (await ev(t, 'app_open', at(3, 14))).triggered,
    true,
    'rules still evaluate',
  );
  assert.equal(got.length, 0, 'but no brief when disabled');
  t.app.settings.set('catchup.enabled', true);
  t.app.settings.set('catchup.away_hours', 5);
  assert.equal(
    (await ev(t, 'app_open', at(3, 17))).triggered,
    false,
    '3 h < 5 h',
  );
  t.mock.script(text('Nach 6 h'));
  assert.equal((await ev(t, 'app_open', at(3, 23))).triggered, true);
  const r = (await t.app.ops.invoke(
    'catchup.set_settings',
    { away_hours: 1, night_start: '23:00' },
    'agent',
  )) as any;
  assert.deepEqual(r.result.updated, ['away_hours', 'night_start']);
  assert.equal(
    ((await t.app.ops.invoke('catchup.get_settings', {}, 'app')) as any).result
      .night_start,
    '23:00',
  );
});

test('brief uses pending inbox, calendar and the phone location (weather) when connected', async () => {
  const t = makeApp({
    toolTimeoutMs: 2000,
    integrations: {
      calendar: {
        events: async (from) => [
          {
            id: 'e',
            title: 'Zahnarzt',
            start: from + 3_600_000,
            end: from + 7_200_000,
          },
        ],
      },
    },
  });
  t.app.inbox.create({ kind: 'mail', title: 'Rechnung', summary: 'fällig' });
  const sent: any[] = [];
  t.app.hub.add({
    id: 'c',
    deviceId: 'd',
    deviceName: 'd',
    ready: true,
    send: (m) => {
      sent.push(m);
      if (m.type === 'tool_call')
        queueMicrotask(() =>
          t.app.hub.toolResult(
            m.callId as string,
            true,
            'lat 53.55 lon 10.0 (Hamburg)',
          ),
        );
    },
    close() {},
  });
  t.mock.script(text('Rechnung offen, 09:00 Zahnarzt.'));
  t.clock.set(at(3, 9));
  const r = await t.app.catchup.generate('away');
  assert.equal(r!.text, 'Rechnung offen, 09:00 Zahnarzt.');
  const prompt = (t.mock.calls[0]!.messages.at(-1) as any).content as string;
  assert.match(prompt, /Rechnung: fällig/);
  assert.match(prompt, /Zahnarzt/);
  assert.match(prompt, /Hamburg/);
  assert.deepEqual(
    sent.filter((m) => m.type === 'location_access').map((m) => m.phase),
    ['start', 'end'],
  );
  assert.equal(
    t.app.db.all('SELECT * FROM location_log WHERE source=?', 'catchup').length,
    1,
  );
});
