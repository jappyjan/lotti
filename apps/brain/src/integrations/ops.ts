import { z } from 'zod';
import { ApnsPush, APNS_SECRETS } from './push/apns.ts';
import { CodexRuntime } from './runtimes/codex.ts';
import type { App } from '../app.ts';
import { accountRow } from '../ops/integration-ops.ts';
import { defineOp, out, type Operation } from '../ops/registry.ts';
import { accountCalendars, accountMailboxes } from './connectors.ts';
import {
  GOOGLE_SECRETS,
  googleAuthUrl,
  googleClientInfo,
  googleExchange,
} from './google/oauth.ts';

const acc = (app: App, id: string) => {
  const a = accountRow(app, id);
  if (!a) throw new Error('No such account.');
  return a;
};
const setConfig = (app: App, id: string, patch: Record<string, unknown>) => {
  const a = acc(app, id);
  app.db.run(
    'UPDATE accounts SET config=? WHERE id=?',
    JSON.stringify({ ...a.config, ...patch }),
    id,
  );
};

export const accountOps: Operation[] = [
  defineOp({
    name: 'accounts.set_google_client',
    group: 'accounts',
    description:
      'Store the Google OAuth client (clientId, optional clientSecret, optional redirectUri override). Without an override an iOS client (no secret) uses the reversed client id and a Web client (secret) <PUBLIC_URL>/oauth/callback. Write-only; returns the effective redirect.',
    inputSchema: z.object({
      clientId: z.string().min(1),
      clientSecret: z.string().optional(),
      redirectUri: z.string().optional(),
    }),
    risk: 'app_only',
    handler(i, { app }) {
      app.secrets.set(GOOGLE_SECRETS.clientId, i.clientId);
      // A new client replaces the old one completely (secret and override included).
      if (i.clientSecret)
        app.secrets.set(GOOGLE_SECRETS.clientSecret, i.clientSecret);
      else app.secrets.delete(GOOGLE_SECRETS.clientSecret);
      if (i.redirectUri)
        app.secrets.set(GOOGLE_SECRETS.redirect, i.redirectUri);
      else app.secrets.delete(GOOGLE_SECRETS.redirect);
      return googleClientInfo(app);
    },
  }),
  defineOp({
    name: 'accounts.google_client',
    group: 'accounts',
    description:
      'Whether a Google OAuth client is set and which redirect URI sign-in uses: {configured, mode: ios|web|custom, redirectUri, callbackScheme, error?}. Never returns secrets.',
    inputSchema: z.object({}),
    risk: 'app_only',
    handler: (_i, { app }) => googleClientInfo(app),
  }),
  defineOp({
    name: 'accounts.google_auth_url',
    group: 'accounts',
    description:
      'Start Google sign-in: returns {url, state, redirectUri, callbackScheme}. The app opens url in a web auth session and waits for callbackScheme; the redirect carries code and state; then call accounts.google_exchange. Optional accountId re-connects an existing account.',
    inputSchema: z.object({
      accountId: z.string().optional(),
      label: z.string().optional(),
    }),
    risk: 'app_only',
    handler: (i, { app }) =>
      googleAuthUrl(app, {
        ...(i.accountId ? { accountId: i.accountId } : {}),
        ...(i.label ? { label: i.label } : {}),
      }),
  }),
  defineOp({
    name: 'accounts.google_exchange',
    group: 'accounts',
    description:
      'Finish Google sign-in: the app sends the code and state from the redirect; the backend exchanges and stores the tokens (encrypted). Returns {accountId, email}.',
    inputSchema: z.object({
      code: z.string().min(1),
      state: z.string().min(1),
    }),
    risk: 'app_only',
    handler: (i, { app }) => googleExchange(app, i.code, i.state),
  }),
  defineOp({
    name: 'accounts.calendars',
    group: 'accounts',
    description:
      'Calendars of an account (live) with `selected`. No selection stored = all (Google: primary).',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    handler: (i, { app }) => accountCalendars(app, acc(app, i.id)),
  }),
  defineOp({
    name: 'accounts.set_calendars',
    group: 'accounts',
    description:
      'Choose which calendar ids of an account Lotti uses (empty = default).',
    inputSchema: z.object({ id: z.string(), calendars: z.array(z.string()) }),
    risk: 'tap',
    proposalTitle: (i) => `Choose calendars for ${i.id}`,
    handler(i, { app }) {
      const prev = acc(app, i.id).config.calendars ?? [];
      setConfig(app, i.id, { calendars: i.calendars });
      return out(
        { id: i.id, calendars: i.calendars },
        {
          undo: {
            label: 'Calendar selection back',
            op: 'accounts.set_calendars',
            input: { id: i.id, calendars: prev },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'accounts.mailboxes',
    group: 'accounts',
    description:
      'Mailboxes of an IMAP account (live) with `selected` (default INBOX). Gmail has none.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    handler: (i, { app }) => accountMailboxes(app, acc(app, i.id)),
  }),
  defineOp({
    name: 'accounts.set_mailboxes',
    group: 'accounts',
    description:
      'Choose which mailboxes of an IMAP account Lotti searches (empty = INBOX).',
    inputSchema: z.object({ id: z.string(), mailboxes: z.array(z.string()) }),
    risk: 'tap',
    proposalTitle: (i) => `Choose mailboxes for ${i.id}`,
    handler(i, { app }) {
      const prev = acc(app, i.id).config.mailboxes ?? [];
      setConfig(app, i.id, { mailboxes: i.mailboxes });
      return out(
        { id: i.id, mailboxes: i.mailboxes },
        {
          undo: {
            label: 'Mailbox selection back',
            op: 'accounts.set_mailboxes',
            input: { id: i.id, mailboxes: prev },
          },
        },
      );
    },
  }),

  // ---- providers: Codex subscription login ---------------------------------------------------------
  defineOp({
    name: 'providers.codex_login_start',
    group: 'providers',
    description:
      'Start the Codex (ChatGPT) device login on the server. Returns {state, url, code}: the app shows them; the user opens url on any device and enters code. Poll providers.codex_login_status.',
    inputSchema: z.object({}),
    risk: 'app_only',
    async handler(_i, { app }) {
      const c = app.providers.get('codex');
      if (!(c instanceof CodexRuntime))
        throw new Error('Codex runtime is not installed.');
      return c.loginStart();
    },
  }),
  defineOp({
    name: 'providers.codex_login_status',
    group: 'providers',
    description:
      'State of the Codex login: {state: idle|pending|done|error, loggedIn, url?, code?, error?}.',
    inputSchema: z.object({}),
    risk: 'free',
    async handler(_i, { app }) {
      const c = app.providers.get('codex');
      if (!(c instanceof CodexRuntime))
        throw new Error('Codex runtime is not installed.');
      const r = await c.loginStatus();
      if (r.loggedIn) app.providers.noteOk('codex');
      return r;
    },
  }),
  defineOp({
    name: 'providers.codex_logout',
    group: 'providers',
    description: 'Sign Codex out on the server.',
    inputSchema: z.object({}),
    risk: 'app_only',
    async handler(_i, { app }) {
      const c = app.providers.get('codex');
      if (!(c instanceof CodexRuntime))
        throw new Error('Codex runtime is not installed.');
      await c.logout();
      return { loggedIn: false };
    },
  }),

  // ---- push (APNs) -------------------------------------------------------------------------------------
  defineOp({
    name: 'push.configure',
    group: 'push',
    description:
      'Set up APNs: the .p8 key text, keyId, teamId, bundle id (topic) and production/sandbox. Write-only.',
    inputSchema: z.object({
      key: z.string().min(20),
      keyId: z.string().min(1),
      teamId: z.string().min(1),
      topic: z.string().min(1),
      production: z.boolean().optional(),
    }),
    risk: 'app_only',
    handler(i, { app }) {
      app.secrets.set(APNS_SECRETS.key, i.key);
      app.secrets.set(APNS_SECRETS.keyId, i.keyId);
      app.secrets.set(APNS_SECRETS.teamId, i.teamId);
      app.secrets.set(APNS_SECRETS.topic, i.topic);
      if (i.production !== undefined)
        app.settings.set('push.apns.production', i.production);
      return { configured: app.integrations.push.configured?.() ?? true };
    },
  }),
  defineOp({
    name: 'push.clear',
    group: 'push',
    description: 'Remove the stored APNs credentials (push goes off).',
    inputSchema: z.object({}),
    risk: 'app_only',
    handler(_i, { app }) {
      for (const k of Object.values(APNS_SECRETS)) app.secrets.delete(k);
      return { configured: app.integrations.push.configured?.() ?? false };
    },
  }),
  defineOp({
    name: 'push.test',
    group: 'push',
    description:
      'Send a test push to one device (or all devices that have an APNs token).',
    inputSchema: z.object({ deviceId: z.string().optional() }),
    risk: 'app_only',
    async handler(i, { app }) {
      const p = app.integrations.push;
      if (!(p instanceof ApnsPush)) throw new Error('APNs is not installed.');
      if (!p.configured())
        throw new Error('APNs is not configured yet (push.configure).');
      const devices = app.auth
        .devices()
        .filter((d) => d.apnsToken && (!i.deviceId || d.id === i.deviceId));
      if (!devices.length) throw new Error('No device with an APNs token.');
      const results = [];
      for (const d of devices)
        results.push({
          device: d.name,
          ...(await p.send(d, {
            aps: {
              alert: { title: 'Lotti', body: 'Test push' },
              sound: 'default',
              'content-available': 1,
            },
            test: true,
          })),
        });
      return results;
    },
  }),
];
