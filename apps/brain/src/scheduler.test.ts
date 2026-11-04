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
  // the app counts down to the start, not to the (later) expiry
  assert.match(t.app.inbox.list()[0]!.startsAt!, /^2026-11-03T08:08:00/);
  assert.notEqual(
    t.app.inbox.list()[0]!.startsAt,
    t.app.inbox.list()[0]!.expiresAt,
  );
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

test('important_mail: `since` moves only after triage succeeded, to the fetch start time', async () => {
  const sinces: number[] = [];
  const t = makeApp({
    integrations: {
      mail: {
        unread: async (since) => {
          sinces.push(since);
          return [{ id: 'm1', from: 'a@b', subject: 'Frist', snippet: 'heute', receivedAt: 1 }];
        },
      },
    },
  });
  const job = t.app.scheduler.list().find((j) => j.builtinKey === 'important_mail')!;
  const before = String(t.clock.now() - 600_000);
  t.app.settings.kvSet('important_mail.since', before);
  t.mock.script(() => {
    throw new Error('LLM down');
  });
  const fail = await t.app.scheduler.runNow(job.id);
  assert.equal(fail.status, 'error');
  assert.equal(t.app.settings.kvGet('important_mail.since'), before, 'not advanced on failure');
  t.clock.advanceMinutes(10);
  const fetchStart = t.clock.now();
  t.mock.script(() => {
    t.clock.advanceMinutes(1); // triage takes a while
    return text('[{"id":"m1","important":true,"title":"Frist","summary":"heute"}]');
  });
  const ok = await t.app.scheduler.runNow(job.id);
  assert.equal(ok.status, 'ok');
  assert.equal(sinces[1], sinces[0], 'the retry asks for the same mail again');
  assert.equal(Number(t.app.settings.kvGet('important_mail.since')), fetchStart);
  assert.equal(t.app.inbox.list().length, 1);
});

test('overlapping ticks never run a job twice; due state is re-checked before each run', async () => {
  const t = makeApp();
  let runs = 0;
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  t.mock.script(async () => {
    runs++;
    await gate;
    return text('NOTHING');
  });
  const a = t.app.scheduler.create({ name: 'A', prompt: 'a', schedule: 'every 10 minutes' });
  const b = t.app.scheduler.create({ name: 'B', prompt: 'b', schedule: 'every 10 minutes' });
  t.clock.advanceMinutes(11);
  const first = t.app.scheduler.tick(); // runs A, blocks
  await new Promise((r) => setTimeout(r, 10));
  await t.app.scheduler.tick(); // skipped: the first one is still in progress
  // B runs manually meanwhile: its next run moves into the future, so the first tick must not run it again
  t.mock.script(text('NOTHING'));
  t.app.db.run('UPDATE jobs SET next_run_at=? WHERE id=?', t.clock.now() + 600_000, b.id);
  release();
  await first;
  assert.equal(t.app.scheduler.history(a.id).length, 1);
  assert.equal(t.app.scheduler.history(b.id).length, 0, 'B was no longer due');
  assert.equal(runs, 1);
});

test('job_runs are pruned per job; retention sweep drops old logs; catch-up reads user runs directly', async () => {
  const { RUNS_KEPT_PER_JOB } = await import('./scheduler/scheduler.ts');
  const t = makeApp();
  const job = t.app.scheduler.list().find((j) => j.builtinKey === 'meeting_soon')!;
  for (let i = 0; i < RUNS_KEPT_PER_JOB + 5; i++) {
    t.clock.advanceMinutes(1);
    await t.app.scheduler.runNow(job.id);
  }
  assert.equal(
    t.app.db.get<{ n: number }>('SELECT COUNT(*) AS n FROM job_runs WHERE job_id=?', job.id)!.n,
    RUNS_KEPT_PER_JOB,
  );
  const user = t.app.scheduler.create({ name: 'Bahn', prompt: 'p', schedule: 'daily at 07:00' });
  t.mock.script(text('S-Bahn fällt aus.'));
  await t.app.scheduler.runNow(user.id);
  assert.deepEqual(
    t.app.scheduler.recentUserRuns(t.clock.now() - 3_600_000).map((r) => [r.name, r.output]),
    [['Bahn', 'S-Bahn fällt aus.']],
  );

  t.app.db.run("INSERT INTO shell_log(at,command) VALUES(?, 'old')", t.clock.now() - 31 * 86_400_000);
  t.app.db.run("INSERT INTO shell_log(at,command) VALUES(?, 'new')", t.clock.now());
  const it = t.app.inbox.create({ title: 'alt' });
  t.app.inbox.dismiss(it.id);
  t.clock.advanceMinutes(31 * 24 * 60);
  const keep = t.app.inbox.create({ title: 'offen' });
  t.app.scheduler.sweepRetention();
  assert.deepEqual(
    t.app.db.all<{ command: string }>('SELECT command FROM shell_log').map((r) => r.command),
    [],
    'both are older than 30 days now',
  );
  assert.equal(t.app.inbox.get(it.id), undefined);
  assert.ok(t.app.inbox.get(keep.id));
});

test('meeting soon lead time is a setting (jobs.meeting_soon.lead_min)', async () => {
  const windows: number[] = [];
  const t = makeApp({
    integrations: {
      calendar: {
        events: async (from, to) => {
          windows.push((to - from) / 60_000);
          return [];
        },
      },
    },
  });
  const job = t.app.scheduler.list().find((j) => j.builtinKey === 'meeting_soon')!;
  await t.app.scheduler.runNow(job.id);
  assert.equal(
    ((await t.app.ops.invoke('settings.set', { key: 'jobs.meeting_soon.lead_min', value: 25 }, 'agent')) as any).ok,
    true,
  );
  await t.app.scheduler.runNow(job.id);
  assert.deepEqual(windows, [10, 25]);
});

test('"run dreaming now" by voice: the agent sees dreaming_run_now (free, no tap)', async () => {
  const t = makeApp();
  const names = t.app.tools.all().map((x) => x.name);
  assert.ok(names.includes('dreaming_run_now'));
  assert.ok(names.includes('dreaming_reports'));
  t.mock.script(call('dreaming_run_now', {}), answer('Fertig geträumt.'));
  const r = await t.app.ask({ text: 'Träum jetzt', channel: 'phone', locale: 'de' });
  assert.equal(r.text, 'Fertig geträumt.');
  assert.equal(r.actions.length, 0, 'ran at once');
  assert.equal(t.app.dreaming.reports().length, 1);
});
