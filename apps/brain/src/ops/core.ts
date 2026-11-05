import { z } from 'zod';
import { isProviderManaged, SETTING_DEFS } from '../settings.ts';
import { isoLocal } from '../util/clock.ts';
import { defineOp, out } from './registry.ts';

const providerId = z.string().min(1);

/** provider.* settings belong to the providers.* ops (a tap for the agent and the admin MCP). */
function refuseProviderKey(key: string): void {
  if (isProviderManaged(key))
    throw new Error(
      `${key} is managed by the providers.* operations (providers.set_active, providers.set_model).`,
    );
}

export const coreOps = [
  // ---- status ---------------------------------------------------------------
  defineOp({
    name: 'status.get',
    group: 'status',
    description:
      'Server status: version, time, providers, connected devices, counts.',
    inputSchema: z.object({}),
    risk: 'free',
    handler(_i, { app }) {
      return {
        version: app.config.version,
        now: isoLocal(app.clock.now()),
        uptimeSec: Math.round((app.clock.now() - app.startedAt) / 1000),
        activeProvider: app.providers.activeId(),
        fallbackProvider: app.providers.fallbackId() || null,
        providers: app.providers.status().map((p) => ({
          id: p.id,
          configured: p.configured,
          lastError: p.lastError,
        })),
        connectedDevices: app.hub.connectedDeviceIds().length,
        pairedDevices: app.auth.devices().length,
        memories: app.memory.count(),
        jobs: app.scheduler.list().length,
        inboxPending: app.inbox.pending().length,
        adminMcpEnabled: app.auth.adminTokens().length > 0,
      };
    },
  }),

  // ---- providers ------------------------------------------------------------
  defineOp({
    name: 'providers.list',
    group: 'providers',
    description:
      'All model providers with configured flag, model, active/fallback and last error.',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) => app.providers.status(),
  }),
  defineOp({
    name: 'providers.status',
    group: 'providers',
    description: 'Status of one provider (configured, model, last error).',
    inputSchema: z.object({ provider: providerId }),
    risk: 'free',
    handler(i, { app }) {
      const s = app.providers.status().find((p) => p.id === i.provider);
      if (!s) throw new Error(`Unknown provider ${i.provider}`);
      return s;
    },
  }),
  defineOp({
    name: 'providers.set_active',
    group: 'providers',
    description:
      'Choose the active provider and optionally the fallback (used on error or timeout). Empty fallback = none.',
    inputSchema: z.object({
      active: providerId,
      fallback: z.string().optional(),
    }),
    risk: 'tap',
    proposalTitle: (i) =>
      `Switch provider to ${i.active}${i.fallback ? ` (fallback ${i.fallback})` : ''}`,
    handler(i, { app }) {
      for (const id of [i.active, i.fallback].filter(Boolean) as string[])
        if (!app.providers.get(id)) throw new Error(`Unknown provider ${id}`);
      const prev = {
        active: app.providers.activeId(),
        fallback: app.providers.fallbackId(),
      };
      app.settings.set('provider.active', i.active);
      if (i.fallback !== undefined)
        app.settings.set('provider.fallback', i.fallback);
      return out(
        { active: i.active, fallback: app.providers.fallbackId() || null },
        {
          undo: {
            label: 'Provider back to ' + prev.active,
            op: 'providers.set_active',
            input: prev,
          },
        },
      );
    },
  }),
  defineOp({
    name: 'providers.set_model',
    group: 'providers',
    description: 'Set the model id used for a provider.',
    inputSchema: z.object({ provider: providerId, model: z.string().min(1) }),
    risk: 'tap',
    proposalTitle: (i) => `Use model ${i.model} for ${i.provider}`,
    handler(i, { app }) {
      if (!app.providers.get(i.provider))
        throw new Error(`Unknown provider ${i.provider}`);
      const key = `provider.${i.provider}.model`;
      const prev = app.settings.str(key);
      app.settings.set(key, i.model);
      return out(
        { provider: i.provider, model: i.model },
        {
          undo: {
            label: `Model back to ${prev}`,
            op: 'providers.set_model',
            input: {
              provider: i.provider,
              model: prev || app.providers.get(i.provider)!.defaultModel,
            },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'providers.models',
    group: 'providers',
    description:
      'Model ids a provider offers (live list when the key works, else suggestions).',
    inputSchema: z.object({ provider: providerId }),
    risk: 'free',
    async handler(i, { app }) {
      const p = app.providers.get(i.provider);
      if (!p) throw new Error(`Unknown provider ${i.provider}`);
      if (p.kind === 'chat' && p.configured() && p.listModels) {
        try {
          return {
            source: 'live',
            // Suggestions stay in the list: a provider's own list may lag behind new models.
            models: [
              ...new Set([
                ...p.knownModels,
                ...(await p.listModels(AbortSignal.timeout(8000))),
              ]),
            ],
          };
        } catch (e) {
          return {
            source: 'suggested',
            models: p.knownModels,
            error: e instanceof Error ? e.message : String(e),
          };
        }
      }
      return { source: 'suggested', models: p.knownModels };
    },
  }),
  defineOp({
    name: 'providers.set_credential',
    group: 'providers',
    description: 'Store a provider API key (write-only).',
    inputSchema: z.object({ provider: providerId, apiKey: z.string().min(1) }),
    risk: 'app_only',
    handler(i, { app }) {
      if (!app.providers.get(i.provider))
        throw new Error(`Unknown provider ${i.provider}`);
      app.secrets.set(`provider.${i.provider}.api_key`, i.apiKey);
      return { provider: i.provider, configured: true };
    },
  }),
  defineOp({
    name: 'providers.clear_credential',
    group: 'providers',
    description: 'Remove a provider API key.',
    inputSchema: z.object({ provider: providerId }),
    risk: 'app_only',
    handler: (i, { app }) => ({
      removed: app.secrets.delete(`provider.${i.provider}.api_key`),
    }),
  }),

  // ---- settings -------------------------------------------------------------
  defineOp({
    name: 'settings.list',
    group: 'settings',
    description:
      'All settings with value, default, description, whether they are safety settings, and managedBy ("providers" = change them with the providers.* ops).',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) => app.settings.all(),
  }),
  defineOp({
    name: 'settings.get',
    group: 'settings',
    description: 'Get one setting.',
    inputSchema: z.object({ key: z.string() }),
    risk: 'free',
    handler(i, { app }) {
      if (!SETTING_DEFS[i.key]) throw new Error(`Unknown setting ${i.key}`);
      return { key: i.key, value: app.settings.get(i.key) };
    },
  }),
  defineOp({
    name: 'settings.set',
    group: 'settings',
    description:
      'Change a (non-safety) setting. Safety settings use settings.set_safety.',
    inputSchema: z.object({ key: z.string(), value: z.unknown() }),
    risk: 'free',
    handler(i, { app }) {
      const def = SETTING_DEFS[i.key];
      if (!def) throw new Error(`Unknown setting ${i.key}`);
      refuseProviderKey(i.key);
      if (app.settings.isSafety(i.key))
        throw new Error(
          `${i.key} is a safety setting: use settings.set_safety (needs confirmation).`,
        );
      if (
        def.int &&
        !(
          Number.isInteger(i.value) &&
          (i.value as number) >= def.int.min &&
          (i.value as number) <= def.int.max
        )
      )
        throw new Error(
          `${i.key} must be a whole number from ${def.int.min} to ${def.int.max}.`,
        );
      const prev = app.settings.get(i.key);
      app.settings.set(i.key, i.value);
      return out(
        { key: i.key, value: i.value },
        {
          undo: {
            label: `${i.key} back to ${JSON.stringify(prev)}`,
            op: 'settings.set',
            input: { key: i.key, value: prev },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'settings.set_safety',
    group: 'settings',
    description:
      "Change a safety setting (shell, web fetch, location, step limit, which ops the agent may use). Needs the user's confirmation when the agent asks.",
    inputSchema: z.object({ key: z.string(), value: z.unknown() }),
    risk: 'tap',
    proposalTitle: (i) => `Set ${i.key} = ${JSON.stringify(i.value)}`,
    handler(i, { app }) {
      if (!SETTING_DEFS[i.key]) throw new Error(`Unknown setting ${i.key}`);
      if (!app.settings.isSafety(i.key))
        throw new Error(`${i.key} is not a safety setting: use settings.set.`);
      const prev = app.settings.get(i.key);
      app.settings.set(i.key, i.value);
      return out(
        { key: i.key, value: i.value },
        {
          undo: {
            label: `${i.key} back to ${JSON.stringify(prev)}`,
            op: 'settings.set_safety',
            input: { key: i.key, value: prev },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'settings.reset',
    group: 'settings',
    description: 'Reset a non-safety setting to its default.',
    inputSchema: z.object({ key: z.string() }),
    risk: 'free',
    handler(i, { app }) {
      if (!SETTING_DEFS[i.key]) throw new Error(`Unknown setting ${i.key}`);
      refuseProviderKey(i.key);
      if (app.settings.isSafety(i.key))
        throw new Error(
          'Safety settings cannot be reset by the agent; use settings.set_safety.',
        );
      app.settings.reset(i.key);
      return { key: i.key, value: app.settings.get(i.key) };
    },
  }),

  // ---- secrets (write-only) --------------------------------------------------
  defineOp({
    name: 'secrets.set',
    group: 'accounts',
    description: 'Store a secret (encrypted, write-only).',
    inputSchema: z.object({
      name: z.string().min(1),
      value: z.string().min(1),
    }),
    risk: 'app_only',
    handler(i, { app }) {
      app.secrets.set(i.name, i.value);
      return { name: i.name, set: true };
    },
  }),
  defineOp({
    name: 'secrets.delete',
    group: 'accounts',
    description: 'Delete a secret.',
    inputSchema: z.object({ name: z.string().min(1) }),
    risk: 'app_only',
    handler: (i, { app }) => ({ deleted: app.secrets.delete(i.name) }),
  }),
  defineOp({
    name: 'secrets.list',
    group: 'accounts',
    description: 'Secret names and status only (never values).',
    inputSchema: z.object({ prefix: z.string().optional() }),
    risk: 'app_only',
    handler: (i, { app }) =>
      app.secrets.list(i.prefix ?? '').map((s) => ({
        name: s.name,
        set: true,
        updatedAt: isoLocal(s.updatedAt),
      })),
  }),

  // ---- pairing -----------------------------------------------------------------
  defineOp({
    name: 'pairing.new_code',
    group: 'status',
    description: 'Create a one-time pairing code for another device.',
    inputSchema: z.object({}),
    risk: 'app_only',
    handler: (_i, { app }) => ({
      code: app.auth.newPairingCode(),
      url: app.config.publicUrl,
    }),
  }),
  defineOp({
    name: 'pairing.devices',
    group: 'status',
    description: 'Paired devices.',
    inputSchema: z.object({}),
    risk: 'app_only',
    handler: (_i, { app, deviceId }) =>
      app.auth.devices().map((d) => ({
        id: d.id,
        name: d.name,
        createdAt: isoLocal(d.createdAt),
        lastSeenAt: d.lastSeenAt ? isoLocal(d.lastSeenAt) : null,
        connected: app.hub.connectedDeviceIds().includes(d.id),
        isSelf: d.id === deviceId,
      })),
  }),
  defineOp({
    name: 'pairing.revoke_device',
    group: 'status',
    description: 'Revoke a paired device (its token stops working).',
    inputSchema: z.object({ id: z.string() }),
    risk: 'app_only',
    handler: (i, { app }) => {
      const revoked = app.auth.revokeDevice(i.id);
      if (revoked) app.hub.disconnectDevice(i.id);
      return { revoked };
    },
  }),

  // ---- admin token ---------------------------------------------------------------
  defineOp({
    name: 'admin_token.create',
    group: 'admin_token',
    description:
      'Create a token for the Lotti admin MCP server (/mcp/admin). Shown once. The admin MCP is off until a token exists.',
    inputSchema: z.object({ name: z.string().default('admin') }),
    risk: 'app_only',
    handler(i, { app }) {
      const t = app.auth.createAdminToken(i.name);
      return {
        id: t.id,
        token: t.token,
        url: `${app.config.publicUrl}/mcp/admin`,
        note: 'This token is shown only now.',
      };
    },
  }),
  defineOp({
    name: 'admin_token.revoke',
    group: 'admin_token',
    description: 'Revoke an admin MCP token.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'app_only',
    handler: (i, { app }) => ({ revoked: app.auth.revokeAdminToken(i.id) }),
  }),
  defineOp({
    name: 'admin_token.status',
    group: 'admin_token',
    description:
      'Whether the admin MCP is on and which tokens exist (never the tokens).',
    inputSchema: z.object({}),
    risk: 'app_only',
    handler(_i, { app }) {
      const t = app.auth.adminTokens();
      return {
        enabled: t.length > 0,
        url: `${app.config.publicUrl}/mcp/admin`,
        tokens: t.map((x) => ({
          ...x,
          createdAt: isoLocal(x.createdAt),
          lastUsedAt: x.lastUsedAt ? isoLocal(x.lastUsedAt) : null,
        })),
      };
    },
  }),

  // ---- push --------------------------------------------------------------------
  defineOp({
    name: 'push.status',
    group: 'push',
    description:
      'Push status: APNs configured, devices with a token, queued items.',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) => ({
      apnsConfigured: app.integrations.push.configured?.() ?? !!app.config.apns,
      devices: app.auth.devices().map((d) => ({
        id: d.id,
        name: d.name,
        hasApnsToken: !!d.apnsToken,
        connected: app.hub.connectedDeviceIds().includes(d.id),
      })),
      queued: app.inbox.queueDepth(),
    }),
  }),

  // ---- privacy -------------------------------------------------------------------
  defineOp({
    name: 'privacy.location_log',
    group: 'privacy',
    description: 'Log of every location read (when, by whom, success).',
    inputSchema: z.object({
      limit: z.number().int().min(1).max(500).default(50),
    }),
    risk: 'free',
    handler: (i, { app }) =>
      app.db
        .all<{
          at: number;
          call_id: string;
          source: string;
          ask_id: string | null;
          ok: number;
        }>('SELECT * FROM location_log ORDER BY id DESC LIMIT ?', i.limit)
        .map((r) => ({
          at: isoLocal(r.at),
          callId: r.call_id,
          source: r.source,
          askId: r.ask_id,
          ok: !!r.ok,
        })),
  }),
  defineOp({
    name: 'privacy.shell_log',
    group: 'privacy',
    description: 'Log of every shell command the agent ran.',
    inputSchema: z.object({
      limit: z.number().int().min(1).max(500).default(50),
    }),
    risk: 'free',
    handler: (i, { app }) =>
      app.db
        .all<{
          at: number;
          command: string;
          exit_code: number | null;
          duration_ms: number;
          timed_out: number;
          truncated: number;
          output: string;
        }>('SELECT * FROM shell_log ORDER BY id DESC LIMIT ?', i.limit)
        .map((r) => ({
          at: isoLocal(r.at),
          command: r.command,
          exitCode: r.exit_code,
          durationMs: r.duration_ms,
          timedOut: !!r.timed_out,
          truncated: !!r.truncated,
          output: r.output,
        })),
  }),
];
