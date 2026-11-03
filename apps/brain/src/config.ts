import { resolve } from 'node:path';

export interface Config {
  masterKey: string;
  publicUrl: string;
  port: number;
  dataDir: string;
  dbPath: string;
  workspaceDir: string;
  apns?: {
    keyId: string;
    teamId: string;
    key: string;
    topic: string;
    production: boolean;
  };
  /** Phone tool timeout (protocol: 10 s). Overridable for tests. */
  phoneToolTimeoutMs: number;
  version: string;
}

export function loadConfig(
  env: Record<string, string | undefined> = process.env,
): Config {
  const masterKey = env.MASTER_KEY;
  if (!masterKey || masterKey.length < 16) {
    throw new Error(
      'MASTER_KEY is required (at least 16 characters; try `openssl rand -hex 32`).',
    );
  }
  const port = Number(env.PORT ?? 8787);
  const dataDir = resolve(env.DATA_DIR ?? '/data');
  const apns =
    env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_KEY && env.APNS_TOPIC
      ? {
          keyId: env.APNS_KEY_ID,
          teamId: env.APNS_TEAM_ID,
          key: env.APNS_KEY,
          topic: env.APNS_TOPIC,
          production: env.APNS_PRODUCTION !== '0',
        }
      : undefined;
  return {
    masterKey,
    publicUrl: (env.PUBLIC_URL ?? `http://localhost:${port}`).replace(
      /\/+$/,
      '',
    ),
    port,
    dataDir,
    dbPath: resolve(dataDir, 'lotti.db'),
    workspaceDir: resolve(dataDir, 'workspace'),
    apns,
    phoneToolTimeoutMs: 10_000,
    version: '0.1.0',
  };
}
