import type { App } from './app.ts';
import {
  pairingCode,
  newId,
  randomToken,
  safeEqual,
  sha256,
} from './util/crypto.ts';
import type { DeviceInfo } from './integrations/index.ts';

/** Pairing codes expire 15 minutes after they were created. */
export const PAIRING_CODE_TTL_MS = 15 * 60_000;

export interface Device extends DeviceInfo {
  createdAt: number;
  lastSeenAt: number | null;
}

/** Pairing codes, device tokens (hashed), admin tokens (hashed) and the internal MCP token. */
export class Auth {
  constructor(private app: App) {}

  // ---- pairing --------------------------------------------------------
  /** The newest unused pairing code that has not expired (codes live PAIRING_CODE_TTL_MS). */
  currentPairingCode(): string | undefined {
    return this.app.db.get<{ code: string }>(
      'SELECT code FROM pairing_codes WHERE used_at IS NULL AND created_at > ? ORDER BY created_at DESC LIMIT 1',
      this.app.clock.now() - PAIRING_CODE_TTL_MS,
    )?.code;
  }
  /** A fresh code; older unused codes stop working. */
  newPairingCode(): string {
    const code = pairingCode();
    this.app.db.tx(() => {
      this.app.db.run('DELETE FROM pairing_codes WHERE used_at IS NULL');
      this.app.db.run(
        'INSERT INTO pairing_codes(code, created_at) VALUES(?,?)',
        code,
        this.app.clock.now(),
      );
    });
    return code;
  }
  hasDevices(): boolean {
    return !!this.app.db.get(
      'SELECT 1 AS x FROM devices WHERE revoked_at IS NULL',
    );
  }
  /** Code to show in the logs at startup: only while no device is paired (re-issued once the old one expired). */
  ensureStartupCode(): string | undefined {
    if (this.hasDevices()) return undefined;
    return this.currentPairingCode() ?? this.newPairingCode();
  }
  /** Single-use. Returns the device token, or null if the code is wrong/used/expired. */
  pair(
    code: string,
    deviceName: string,
  ): { token: string; deviceId: string } | null {
    const norm = code.trim().toUpperCase().replace(/\s/g, '');
    const row = this.app.db.get<{ code: string }>(
      'SELECT code FROM pairing_codes WHERE used_at IS NULL AND code = ? AND created_at > ?',
      norm.includes('-') ? norm : `${norm.slice(0, 4)}-${norm.slice(4)}`,
      this.app.clock.now() - PAIRING_CODE_TTL_MS,
    );
    if (!row) return null;
    const token = randomToken('lt_');
    const id = newId('dev_');
    const now = this.app.clock.now();
    this.app.db.tx(() => {
      this.app.db.run(
        'UPDATE pairing_codes SET used_at=? WHERE code=?',
        now,
        row.code,
      );
      this.app.db.run(
        'INSERT INTO devices(id,name,token_hash,created_at) VALUES(?,?,?,?)',
        id,
        deviceName.slice(0, 80) || 'device',
        sha256(token),
        now,
      );
    });
    return { token, deviceId: id };
  }

  // ---- device tokens --------------------------------------------------
  verifyDevice(token: string | undefined): Device | null {
    if (!token) return null;
    const r = this.app.db.get<{
      id: string;
      name: string;
      apns_token: string | null;
      created_at: number;
      last_seen_at: number | null;
    }>(
      'SELECT * FROM devices WHERE token_hash=? AND revoked_at IS NULL',
      sha256(token),
    );
    if (!r) return null;
    return {
      id: r.id,
      name: r.name,
      apnsToken: r.apns_token,
      createdAt: r.created_at,
      lastSeenAt: r.last_seen_at,
    };
  }
  touchDevice(id: string, name?: string, apnsToken?: string): void {
    this.app.db.run(
      'UPDATE devices SET last_seen_at=?, name=COALESCE(?,name), apns_token=COALESCE(?,apns_token) WHERE id=?',
      this.app.clock.now(),
      name ?? null,
      apnsToken ?? null,
      id,
    );
  }
  devices(): Device[] {
    return this.app.db
      .all<{
        id: string;
        name: string;
        apns_token: string | null;
        created_at: number;
        last_seen_at: number | null;
      }>('SELECT * FROM devices WHERE revoked_at IS NULL ORDER BY created_at')
      .map((r) => ({
        id: r.id,
        name: r.name,
        apnsToken: r.apns_token,
        createdAt: r.created_at,
        lastSeenAt: r.last_seen_at,
      }));
  }
  revokeDevice(id: string): boolean {
    return (
      this.app.db.run(
        'UPDATE devices SET revoked_at=? WHERE id=? AND revoked_at IS NULL',
        this.app.clock.now(),
        id,
      ).changes > 0
    );
  }

  // ---- admin tokens (Lotti admin MCP) ----------------------------------
  createAdminToken(name: string): { id: string; token: string } {
    const token = randomToken('la_');
    const id = newId('adm_');
    this.app.db.run(
      'INSERT INTO admin_tokens(id,name,token_hash,created_at) VALUES(?,?,?,?)',
      id,
      name,
      sha256(token),
      this.app.clock.now(),
    );
    return { id, token };
  }
  verifyAdmin(token: string | undefined): boolean {
    if (!token) return false;
    const r = this.app.db.get<{ id: string }>(
      'SELECT id FROM admin_tokens WHERE token_hash=? AND revoked_at IS NULL',
      sha256(token),
    );
    if (!r) return false;
    this.app.db.run(
      'UPDATE admin_tokens SET last_used_at=? WHERE id=?',
      this.app.clock.now(),
      r.id,
    );
    return true;
  }
  adminTokens(): {
    id: string;
    name: string;
    createdAt: number;
    lastUsedAt: number | null;
  }[] {
    return this.app.db
      .all<{
        id: string;
        name: string;
        created_at: number;
        last_used_at: number | null;
      }>(
        'SELECT id,name,created_at,last_used_at FROM admin_tokens WHERE revoked_at IS NULL ORDER BY created_at',
      )
      .map((r) => ({
        id: r.id,
        name: r.name,
        createdAt: r.created_at,
        lastUsedAt: r.last_used_at,
      }));
  }
  revokeAdminToken(id: string): boolean {
    return (
      this.app.db.run(
        'UPDATE admin_tokens SET revoked_at=? WHERE id=? AND revoked_at IS NULL',
        this.app.clock.now(),
        id,
      ).changes > 0
    );
  }

  // ---- internal token (/mcp/tools, for subscription runtimes) ----------
  internalToken(): string {
    let t = this.app.secrets.get('internal.tools_token');
    if (!t) {
      t = randomToken('li_');
      this.app.secrets.set('internal.tools_token', t);
    }
    return t;
  }
  verifyInternal(token: string | undefined): boolean {
    return !!token && safeEqual(token, this.internalToken());
  }
}
