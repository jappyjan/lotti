import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  friendlyToCron,
  isValidCron,
  nextRun,
  resolveSchedule,
} from './scheduler/cron.ts';
import { answer, call, makeApp, text } from './testing/helpers.ts';

const d = (y: number, mo: number, da: number, h = 0, mi = 0) =>
  new Date(y, mo - 1, da, h, mi).getTime();

test('cron: next run for common expressions (local time)', () => {
  assert.equal(
    nextRun('0 3 * * *', d(2026, 11, 3, 8, 0)),
    d(2026, 11, 4, 3, 0),
  );
  assert.equal(
    nextRun('*/10 * * * *', d(2026, 11, 3, 8, 3)),
    d(2026, 11, 3, 8, 10),
  );
  assert.equal(
    nextRun('* * * * *', d(2026, 11, 3, 8, 0)),
    d(2026, 11, 3, 8, 1),
  );
  assert.equal(
    nextRun('30 7 * * 1-5', d(2026, 11, 6, 8, 0)),
    d(2026, 11, 9, 7, 30),
  ); // Fri -> Mon
  assert.equal(nextRun('0 9 1 * *', d(2026, 11, 3)), d(2026, 12, 1, 9, 0));
  assert.equal(nextRun('0 12 * * 0', d(2026, 11, 3)), d(2026, 11, 8, 12, 0));
  assert.equal(nextRun('0 12 * * 7', d(2026, 11, 3)), d(2026, 11, 8, 12, 0));
  assert.equal(
    nextRun('15,45 * * * *', d(2026, 11, 3, 8, 20)),
    d(2026, 11, 3, 8, 45),
  );
  assert.ok(
    !isValidCron('61 * * * *') &&
      !isValidCron('* * *') &&
      isValidCron('0 0 29 2 *'),
  );
});

test('friendly schedules (en/de) become cron', () => {
  assert.equal(friendlyToCron('every 10 minutes'), '*/10 * * * *');
  assert.equal(friendlyToCron('hourly'), '0 * * * *');
  assert.equal(friendlyToCron('daily at 08:00'), '0 8 * * *');
  assert.equal(friendlyToCron('täglich um 7:30'), '30 7 * * *');
  assert.equal(friendlyToCron('weekdays at 07:30'), '30 7 * * 1-5');
  assert.equal(friendlyToCron('every monday at 9:00'), '0 9 * * 1');
  assert.equal(friendlyToCron('jeden freitag um 17:00'), '0 17 * * 5');
  assert.equal(friendlyToCron('daily at 6pm'), '0 18 * * *');
  assert.equal(friendlyToCron('0 8 * * *'), '0 8 * * *');
  assert.equal(friendlyToCron('whenever'), null);
  assert.throws(() => resolveSchedule('whenever'), /Could not understand/);
});

test('built-in jobs are seeded, editable and cannot be deleted', () => {
  const t = makeApp();
  const jobs = t.app.scheduler.list();
  assert.deepEqual(jobs.map((j) => j.builtinKey).sort(), [
    'dreaming',
    'important_mail',
    'meeting_soon',
  ]);
  const dream = jobs.find((j) => j.builtinKey === 'dreaming')!;
  assert.equal(dream.cron, '0 3 * * *');
  t.app.scheduler.seedBuiltins(); // idempotent
  assert.equal(t.app.scheduler.list().length, 3);
  const upd = t.app.scheduler.update(dream.id, {
    schedule: 'daily at 04:15',
    enabled: false,
  })!;
  assert.deepEqual([upd.cron, upd.enabled], ['15 4 * * *', false]);
  assert.throws(() => t.app.scheduler.delete(dream.id), /cannot be deleted/);
});

test('tick runs due jobs once, records history, advances next_run', async () => {
  const t = makeApp();
  const job = t.app.scheduler.create({
    name: 'Morgen',
    prompt: 'Prüfe etwas',
    schedule: 'daily at 08:30',
  });
  assert.equal(job.nextRunAt?.slice(0, 16), '2026-11-03T08:30');
  t.mock.script(text('NOTHING'));
  await t.app.scheduler.tick();
  assert.equal(
    t.app.scheduler.history(job.id).length,
    0,
    'not due yet at 08:00',
  );
  t.clock.advanceMinutes(31);
  await t.app.scheduler.tick();
  await t.app.scheduler.tick();
  const h = t.app.scheduler.history(job.id);
  assert.equal(h.length, 1, 'ran exactly once');
  assert.equal(h[0]!.status, 'nothing');
  assert.equal(
    t.app.scheduler.get(job.id)!.nextRunAt?.slice(0, 16),
    '2026-11-04T08:30',
  );
  assert.equal(t.app.inbox.list().length, 0);
});

test('user job that reports creates an inbox item; history keeps the output', async () => {
  const t = makeApp();
  const job = t.app.scheduler.create({
    name: 'Paketcheck',
    prompt: 'Sind Pakete da?',
    schedule: 'every 30 minutes',
  });
  t.mock.script(
    call('inbox_create', {
      kind: 'job',
      title: 'Paket da',
      summary: 'DHL liefert heute',
    }),
    answer('Paket-Hinweis angelegt.'),
  );
  t.clock.advanceMinutes(30);
  await t.app.scheduler.tick();
  const run = t.app.scheduler.history(job.id)[0]!;
  assert.equal(run.status, 'ok');
  assert.equal(run.output, 'Paket-Hinweis angelegt.');
  const item = t.app.inbox.list()[0]!;
  assert.deepEqual([item.kind, item.title], ['job', 'Paket da']);
});

test('failing job is recorded as error and keeps running on schedule; disabled jobs do not run', async () => {
  const t = makeApp();
  const job = t.app.scheduler.create({
    name: 'Kaputt',
    prompt: 'x',
    schedule: 'every 10 minutes',
  });
  t.mock.script(() => {
    throw new Error('model down');
  });
  t.clock.advanceMinutes(10);
  await t.app.scheduler.tick();
  assert.deepEqual(
    [
      t.app.scheduler.history(job.id)[0]!.status,
      t.app.scheduler.history(job.id)[0]!.output,
    ],
    ['error', 'model down'],
  );
  t.app.scheduler.update(job.id, { enabled: false });
  t.clock.advanceMinutes(20);
  await t.app.scheduler.tick();
  assert.equal(t.app.scheduler.history(job.id).length, 1);
  const r = await t.app.ops.invoke('jobs.run_now', { id: job.id }, 'app');
  assert.ok(r.ok, 'run_now works even when disabled');
  assert.equal(t.app.scheduler.history(job.id).length, 2);
});

test('built-in meeting_soon uses the pluggable calendar and dedupes', async () => {
  const t = makeApp({
    integrations: {
      calendar: {
        events: async (_from, to) =>
          [
            {
              id: 'e1',
              title: 'Standup',
              start: new Date(2026, 10, 3, 8, 8).getTime(),
              end: new Date(2026, 10, 3, 8, 38).getTime(),
              location: 'Raum 4',
            },
          ].filter((e) => e.start <= to),
      },
    },
  });
  const job = t.app.scheduler
    .list()
    .find((j) => j.builtinKey === 'meeting_soon')!;
  const r1 = await t.app.scheduler.runNow(job.id);
  assert.match(r1.output!, /1 meeting/);
  assert.equal(t.app.inbox.list().length, 1);
  assert.equal(t.app.inbox.list()[0]!.kind, 'calendar');
  t.clock.advanceMinutes(1);
  await t.app.scheduler.runNow(job.id);
  assert.equal(t.app.inbox.list().length, 1, 'same meeting not duplicated');
  const none = makeApp();
  assert.match(
    (
      await none.app.scheduler.runNow(
        none.app.scheduler.list().find((j) => j.builtinKey === 'meeting_soon')!
          .id,
      )
    ).output!,
    /No calendar connected/,
  );
});

test('built-in important_mail triages with the LLM via a pluggable mail source', async () => {
  const t = makeApp({
    integrations: {
      mail: {
        unread: async () => [
          {
            id: 'm1',
            from: 'bank@x.de',
            subject: 'Konto gesperrt',
            snippet: 'Bitte handeln',
            receivedAt: 1,
          },
          {
            id: 'm2',
            from: 'news@y.de',
            subject: 'Sale',
            snippet: '-20%',
            receivedAt: 2,
          },
        ],
      },
    },
  });
  t.mock.script(
    text(
      '[{"id":"m1","important":true,"title":"Bank: Konto gesperrt","summary":"Bitte heute handeln"},{"id":"m2","important":false}]',
    ),
  );
  const job = t.app.scheduler
    .list()
    .find((j) => j.builtinKey === 'important_mail')!;
  const run = await t.app.scheduler.runNow(job.id);
  assert.match(run.output!, /2 new mail\(s\), 1 important/);
  const items = t.app.inbox.list();
  assert.equal(items.length, 1);
  assert.deepEqual([items[0]!.kind, items[0]!.sourceRef], ['mail', 'mail:m1']);
});

test('built-in dreaming job runs the dreaming service', async () => {
  const t = makeApp();
  const job = t.app.scheduler.list().find((j) => j.builtinKey === 'dreaming')!;
  const r = await t.app.scheduler.runNow(job.id);
  assert.equal(r.status, 'ok');
  assert.equal(t.app.dreaming.reports().length, 1);
});
