import { z } from 'zod';
import type { Memory } from '../memory.ts';
import type { FileKind } from '../skills.ts';
import { defineOp, out, type Operation } from './registry.ts';

const memoryRestore = z.object({
  memories: z.array(
    z.object({
      id: z.string(),
      text: z.string(),
      kind: z.string().optional(),
      sourceConversation: z.string().nullable().optional(),
    }),
  ),
});

const fileOps = (kind: FileKind, group: 'skills' | 'scripts'): Operation[] => {
  const noun =
    kind === 'skill'
      ? 'skill (markdown how-to the agent can load)'
      : 'script (executable the agent can run with shell)';
  const p = group;
  return [
    defineOp({
      name: `${p}.list`,
      group,
      description: `List ${group} with description and last use.`,
      inputSchema: z.object({}),
      risk: 'free',
      handler: (_i, { app }) => app.skills.list(kind),
    }),
    defineOp({
      name: `${p}.get`,
      group,
      description: `Read a ${noun}.`,
      inputSchema: z.object({ name: z.string() }),
      risk: 'free',
      handler(i, { app }) {
        const c = app.skills.get(kind, i.name);
        if (c === undefined) throw new Error(`No ${kind} named ${i.name}`);
        return { name: i.name, content: c };
      },
    }),
    defineOp({
      name: `${p}.put`,
      group,
      description: `Create or overwrite a ${noun}.`,
      inputSchema: z.object({ name: z.string(), content: z.string() }),
      risk: 'free',
      handler(i, { app }) {
        const prev = app.skills.put(kind, i.name, i.content);
        return out(
          { name: i.name, created: prev === undefined },
          {
            undo:
              prev === undefined
                ? {
                    label: `Remove ${kind} ${i.name}`,
                    op: `${p}.delete`,
                    input: { name: i.name },
                  }
                : {
                    label: `Restore previous ${kind} ${i.name}`,
                    op: `${p}.put`,
                    input: { name: i.name, content: prev },
                  },
          },
        );
      },
    }),
    defineOp({
      name: `${p}.delete`,
      group,
      description: `Delete a ${kind}.`,
      inputSchema: z.object({ name: z.string() }),
      risk: 'free',
      handler(i, { app }) {
        const prev = app.skills.delete(kind, i.name);
        if (prev === undefined) throw new Error(`No ${kind} named ${i.name}`);
        return out(
          { deleted: i.name },
          {
            undo: {
              label: `Restore ${kind} ${i.name}`,
              op: `${p}.put`,
              input: { name: i.name, content: prev },
            },
          },
        );
      },
    }),
  ];
};

export const dataOps: Operation[] = [
  // ---- jobs -------------------------------------------------------------------
  defineOp({
    name: 'jobs.list',
    group: 'jobs',
    description:
      'List jobs (built-in and user jobs) with schedule, enabled and next run.',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) => app.scheduler.list(),
  }),
  defineOp({
    name: 'jobs.create',
    group: 'jobs',
    description:
      'Create a scheduled job: an agent run with a prompt that reports nothing or creates an inbox item. `schedule` is cron ("0 8 * * 1-5") or friendly ("daily at 08:00", "every 30 minutes", "weekdays at 07:30").',
    inputSchema: z.object({
      name: z.string().min(1),
      prompt: z.string().min(1),
      schedule: z.string().min(1),
      enabled: z.boolean().optional(),
      id: z.string().optional(),
    }),
    risk: 'free',
    handler(i, { app }) {
      const job = app.scheduler.create(i);
      return out(job, {
        text: `Created job "${job.name}" (${job.scheduleText}), next run ${job.nextRunAt}.`,
        undo: {
          label: `Delete job ${job.name}`,
          op: 'jobs.delete',
          input: { id: job.id },
        },
      });
    },
  }),
  defineOp({
    name: 'jobs.update',
    group: 'jobs',
    description:
      'Edit a job (name, prompt, schedule, enabled). Built-in jobs can change schedule/enabled.',
    inputSchema: z.object({
      id: z.string(),
      name: z.string().optional(),
      prompt: z.string().optional(),
      schedule: z.string().optional(),
      enabled: z.boolean().optional(),
    }),
    risk: 'free',
    handler(i, { app }) {
      const prev = app.scheduler.get(i.id);
      if (!prev) throw new Error('No such job.');
      const { id, ...patch } = i;
      const job = app.scheduler.update(id, patch)!;
      return out(job, {
        undo: {
          label: `Revert job ${job.name}`,
          op: 'jobs.update',
          input: {
            id,
            name: prev.name,
            ...(prev.prompt !== null ? { prompt: prev.prompt } : {}),
            schedule: prev.cron,
            enabled: prev.enabled,
          },
        },
      });
    },
  }),
  defineOp({
    name: 'jobs.delete',
    group: 'jobs',
    description: 'Delete a user job (built-in jobs can only be disabled).',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    handler(i, { app }) {
      const j = app.scheduler.delete(i.id);
      if (!j) throw new Error('No such job.');
      return out(
        { deleted: j.name },
        {
          undo: {
            label: `Restore job ${j.name}`,
            op: 'jobs.create',
            input: {
              id: j.id,
              name: j.name,
              prompt: j.prompt ?? '',
              schedule: j.cron,
              enabled: j.enabled,
            },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'jobs.run_now',
    group: 'jobs',
    description: 'Run a job right now and return its result.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    async handler(i, { app }) {
      return app.scheduler.runNow(i.id);
    },
  }),
  defineOp({
    name: 'jobs.history',
    group: 'jobs',
    description: 'Run history with outputs (all jobs, or one).',
    inputSchema: z.object({
      id: z.string().optional(),
      limit: z.number().int().min(1).max(200).default(30),
    }),
    risk: 'free',
    handler: (i, { app }) => app.scheduler.history(i.id, i.limit),
  }),

  // ---- memory -----------------------------------------------------------------
  defineOp({
    name: 'memory.list',
    group: 'memory',
    description: 'List memories (newest first).',
    inputSchema: z.object({
      kind: z.string().optional(),
      limit: z.number().int().min(1).max(500).default(100),
      includeSuperseded: z.boolean().optional(),
    }),
    risk: 'free',
    handler: (i, { app }) => app.memory.list(i),
  }),
  defineOp({
    name: 'memory.search',
    group: 'memory',
    description: 'Full-text search in memory.',
    inputSchema: z.object({
      query: z.string().min(1),
      limit: z.number().int().min(1).max(50).default(8),
    }),
    risk: 'free',
    handler: (i, { app }) => app.memory.search(i.query, i.limit),
  }),
  defineOp({
    name: 'memory.get',
    group: 'memory',
    description: 'Get one memory.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    handler(i, { app }) {
      const m = app.memory.get(i.id);
      if (!m) throw new Error('No such memory.');
      return m;
    },
  }),
  defineOp({
    name: 'memory.update',
    group: 'memory',
    description: 'Edit a memory.',
    inputSchema: z.object({
      id: z.string(),
      text: z.string().optional(),
      kind: z.string().optional(),
    }),
    risk: 'free',
    handler(i, { app }) {
      const prev = app.memory.get(i.id);
      if (!prev) throw new Error('No such memory.');
      const m = app.memory.update(i.id, i)!;
      return out(m, {
        undo: {
          label: 'Restore memory text',
          op: 'memory.update',
          input: { id: i.id, text: prev.text, kind: prev.kind },
        },
      });
    },
  }),
  defineOp({
    name: 'memory.delete',
    group: 'memory',
    description: 'Delete a memory by id.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    handler(i, { app }) {
      const m = app.memory.delete(i.id);
      if (!m) throw new Error('No such memory.');
      return out(
        { deleted: m.id },
        {
          undo: {
            label: 'Restore memory',
            op: 'memory.restore',
            input: { memories: [m] },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'memory.remember',
    group: 'memory',
    description:
      'Remember something long-term about the user (a fact, preference, person, place, routine).',
    inputSchema: z.object({
      text: z.string().min(1),
      kind: z
        .enum(['fact', 'preference', 'person', 'place', 'todo'])
        .default('fact'),
    }),
    risk: 'free',
    handler(i, { app }) {
      const m = app.memory.remember(i.text, {
        kind: i.kind,
        source: app.conversations.openRow()?.id ?? null,
      });
      return out(m, {
        text: `Remembered: ${m.text}`,
        undo: {
          label: 'Forget it again',
          op: 'memory.delete',
          input: { id: m.id },
        },
      });
    },
  }),
  defineOp({
    name: 'memory.forget',
    group: 'memory',
    description:
      'Forget memories: by id, or by words (all memories matching every word, max 5).',
    inputSchema: z.object({
      id: z.string().optional(),
      query: z.string().optional(),
    }),
    risk: 'free',
    handler(i, { app }) {
      let targets: Memory[] = [];
      if (i.id) {
        const m = app.memory.get(i.id);
        if (m) targets = [m];
      } else if (i.query)
        targets = app.memory.search(i.query, 5, { all: true });
      else throw new Error('Give an id or a query.');
      if (!targets.length)
        return out({ forgotten: [] }, { text: 'Nothing matched.' });
      for (const m of targets) app.memory.delete(m.id);
      return out(
        { forgotten: targets.map((m) => m.text) },
        {
          text: `Forgot ${targets.length}: ${targets.map((m) => m.text).join('; ')}`,
          undo: {
            label: 'Restore forgotten memories',
            op: 'memory.restore',
            input: { memories: targets },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'memory.restore',
    group: 'memory',
    description: 'Restore deleted memories (used by undo).',
    inputSchema: memoryRestore,
    risk: 'free',
    handler(i, { app }) {
      for (const m of i.memories)
        app.memory.remember(m.text, {
          id: m.id,
          ...(m.kind ? { kind: m.kind } : {}),
          source: m.sourceConversation ?? null,
        });
      return { restored: i.memories.length };
    },
  }),

  // ---- skills & scripts -----------------------------------------------------------
  ...fileOps('skill', 'skills'),
  ...fileOps('script', 'scripts'),

  // ---- conversations ----------------------------------------------------------------
  defineOp({
    name: 'conversations.list',
    group: 'conversations',
    description: 'Recent conversations with title and summary.',
    inputSchema: z.object({
      limit: z.number().int().min(1).max(100).default(20),
    }),
    risk: 'free',
    handler: (i, { app }) => app.conversations.list(i.limit),
  }),
  defineOp({
    name: 'conversations.get',
    group: 'conversations',
    description: 'One conversation with its turns.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    handler(i, { app }) {
      const c = app.conversations.get(i.id);
      if (!c) throw new Error('No such conversation.');
      return c;
    },
  }),
  defineOp({
    name: 'conversations.search',
    group: 'conversations',
    description:
      'Full-text search over conversation titles, summaries and turns.',
    inputSchema: z.object({
      query: z.string().min(1),
      limit: z.number().int().min(1).max(50).default(10),
    }),
    risk: 'free',
    handler: (i, { app }) => app.conversations.search(i.query, i.limit),
  }),

  // ---- inbox -------------------------------------------------------------------------
  defineOp({
    name: 'inbox.list',
    group: 'inbox',
    description: 'List inbox items (default: pending and seen).',
    inputSchema: z.object({
      status: z
        .enum(['open', 'pending', 'seen', 'dismissed', 'expired'])
        .default('open'),
      limit: z.number().int().min(1).max(200).default(50),
    }),
    risk: 'free',
    handler: (i, { app }) => app.inbox.list(i),
  }),
  defineOp({
    name: 'inbox.read',
    group: 'inbox',
    description: 'Read one inbox item (marks it seen).',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    handler(i, { app }) {
      const it = app.inbox.markSeen(i.id);
      if (!it) throw new Error('No such inbox item.');
      return it;
    },
  }),
  defineOp({
    name: 'inbox.dismiss',
    group: 'inbox',
    description: 'Dismiss one inbox item, or all of them with all=true.',
    inputSchema: z.object({
      id: z.string().optional(),
      all: z.boolean().optional(),
    }),
    risk: 'free',
    handler(i, { app }) {
      const ids = i.all
        ? app.inbox.dismissAll()
        : i.id && app.inbox.dismiss(i.id)
          ? [i.id]
          : [];
      if (!i.all && !ids.length) throw new Error('No such inbox item.');
      return out(
        { dismissed: ids },
        {
          text: `Dismissed ${ids.length} item(s).`,
          undo: {
            label: 'Bring back dismissed items',
            op: 'inbox.restore',
            input: { ids },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'inbox.dismiss_all',
    group: 'inbox',
    description: 'Dismiss every open inbox item.',
    inputSchema: z.object({}),
    risk: 'free',
    handler(_i, { app }) {
      const ids = app.inbox.dismissAll();
      return out(
        { dismissed: ids },
        {
          text: `Dismissed ${ids.length} item(s).`,
          undo: {
            label: 'Bring back dismissed items',
            op: 'inbox.restore',
            input: { ids },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'inbox.restore',
    group: 'inbox',
    description: 'Bring dismissed inbox items back (used by undo).',
    inputSchema: z.object({ ids: z.array(z.string()) }),
    risk: 'free',
    handler(i, { app }) {
      for (const id of i.ids) app.inbox.restore(id);
      return { restored: i.ids.length };
    },
  }),
  defineOp({
    name: 'inbox.create',
    group: 'inbox',
    description:
      'Create an inbox item (kind: mail, calendar, job, reminder, info, ...). Pushes it to the phone.',
    inputSchema: z.object({
      kind: z.string().default('info'),
      title: z.string().min(1),
      summary: z.string().default(''),
      body: z.string().default(''),
      sourceRef: z.string().optional(),
      expiresInHours: z.number().min(0).optional(),
      startsAt: z
        .string()
        .optional()
        .describe(
          'Calendar items: when the event starts (ISO 8601 with offset)',
        ),
    }),
    risk: 'free',
    handler(i, { app }) {
      const { startsAt, ...rest } = i;
      const start = startsAt ? Date.parse(startsAt) : NaN;
      if (startsAt && Number.isNaN(start))
        throw new Error(`startsAt "${startsAt}" is not an ISO date.`);
      const it = app.inbox.create({
        ...rest,
        ...(Number.isNaN(start) ? {} : { startsAt: start }),
      });
      return out(it, {
        text: `Created inbox item "${it.title}".`,
        undo: {
          label: 'Dismiss it again',
          op: 'inbox.dismiss',
          input: { id: it.id },
        },
      });
    },
  }),

  // ---- catch-up -------------------------------------------------------------------------
  defineOp({
    name: 'catchup.get_settings',
    group: 'catchup',
    description:
      'Catch-up settings (away hours, night window, sleep threshold, weather).',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) =>
      Object.fromEntries(
        app.settings
          .all()
          .filter((s) => s.key.startsWith('catchup.'))
          .map((s) => [s.key.slice(8), s.value]),
      ),
  }),
  defineOp({
    name: 'catchup.set_settings',
    group: 'catchup',
    description:
      'Change catch-up settings: enabled, away_hours, night_start (HH:MM), night_end, sleep_min_hours, use_weather.',
    inputSchema: z.object({
      enabled: z.boolean().optional(),
      away_hours: z.number().min(0.1).optional(),
      night_start: z
        .string()
        .regex(/^\d{1,2}:\d{2}$/)
        .optional(),
      night_end: z
        .string()
        .regex(/^\d{1,2}:\d{2}$/)
        .optional(),
      sleep_min_hours: z.number().min(0).optional(),
      use_weather: z.boolean().optional(),
    }),
    risk: 'free',
    handler(i, { app }) {
      const changes = Object.entries(i).filter(([, v]) => v !== undefined);
      // All or nothing: one bad value must not leave the others saved without an undo.
      for (const [k, v] of changes) app.settings.check('catchup.' + k, v);
      const prev: Record<string, unknown> = {};
      for (const [k, v] of changes) {
        prev[k] = app.settings.get('catchup.' + k);
        app.settings.set('catchup.' + k, v);
      }
      return out(
        { updated: Object.keys(prev) },
        {
          undo: {
            label: 'Revert catch-up settings',
            op: 'catchup.set_settings',
            input: prev,
          },
        },
      );
    },
  }),
  defineOp({
    name: 'catchup.recent',
    group: 'catchup',
    description: 'Recent catch-up briefs.',
    inputSchema: z.object({
      limit: z.number().int().min(1).max(50).default(10),
    }),
    risk: 'free',
    handler: (i, { app }) => app.catchup.recent(i.limit),
  }),
  defineOp({
    name: 'catchup.run_now',
    group: 'catchup',
    description:
      'Generate a catch-up brief now (sent to the app; nothing if irrelevant).',
    inputSchema: z.object({}),
    risk: 'free',
    async handler(_i, { app }) {
      return (await app.catchup.generate('manual')) ?? { text: null };
    },
  }),

  // ---- dreaming ---------------------------------------------------------------------------
  defineOp({
    name: 'dreaming.run_now',
    group: 'dreaming',
    description:
      'Run memory dreaming now (dedupe, resolve contradictions, drop stale, tidy) and return the report.',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) => app.dreaming.run(),
  }),
  defineOp({
    name: 'dreaming.reports',
    group: 'dreaming',
    description: 'Recent dreaming reports.',
    inputSchema: z.object({
      limit: z.number().int().min(1).max(50).default(10),
    }),
    risk: 'free',
    handler: (i, { app }) => app.dreaming.reports(i.limit),
  }),
];
