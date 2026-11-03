import type { App } from './app.ts';
import { HOUR, isoLocal } from './util/clock.ts';
import { newId } from './util/crypto.ts';

export type InboxStatus = 'pending' | 'seen' | 'dismissed' | 'expired';

export interface InboxItem {
  id: string;
  kind: string; // mail | calendar | job | reminder | info | ... (room for messenger kinds later)
  title: string;
  summary: string;
  body: string;
  sourceRef?: string;
  createdAt: string;
  expiresAt?: string;
  status: InboxStatus;
}

interface Row {
  id: string;
  kind: string;
  title: string;
  summary: string;
  body: string;
  source_ref: string | null;
  created_at: number;
  expires_at: number | null;
  status: InboxStatus;
}

function toItem(r: Row): InboxItem {
  return {
    id: r.id,
    kind: r.kind,
    title: r.title,
    summary: r.summary,
    body: r.body,
    ...(r.source_ref ? { sourceRef: r.source_ref } : {}),
    createdAt: isoLocal(r.created_at),
    ...(r.expires_at ? { expiresAt: isoLocal(r.expires_at) } : {}),
    status: r.status,
  };
}

export interface NewInboxItem {
  kind?: string;
  title: string;
  summary?: string;
  body?: string;
  sourceRef?: string;
  expiresInHours?: number;
  /** Skip creating if an item with the same sourceRef already exists (any status). */
  dedupe?: boolean;
}

/** Server-side source of truth for the inbox; every change is broadcast as an `inbox` message. */
export class InboxService {
  constructor(private app: App) {}

  create(n: NewInboxItem): InboxItem {
    if (n.dedupe && n.sourceRef) {
      const ex = this.app.db.get<Row>(
        'SELECT * FROM inbox WHERE source_ref=?',
        n.sourceRef,
      );
      if (ex) return toItem(ex);
    }
    const now = this.app.clock.now();
    const hours =
      n.expiresInHours ?? this.app.settings.num('inbox.default_expiry_hours');
    const id = newId('in_');
    this.app.db.run(
      `INSERT INTO inbox(id,kind,title,summary,body,source_ref,created_at,expires_at,status,updated_at)
       VALUES(?,?,?,?,?,?,?,?, 'pending', ?)`,
      id,
      n.kind ?? 'info',
      n.title,
      n.summary ?? '',
      n.body ?? '',
      n.sourceRef ?? null,
      now,
      hours > 0 ? now + hours * HOUR : null,
      now,
    );
    const item = this.get(id)!;
    this.app.hub.broadcast({
      type: 'inbox',
      full: false,
      items: [item],
      removedIds: [],
    });
    this.app.hub.broadcast({ type: 'push', item });
    if (!this.app.hub.hasConnections()) {
      for (const d of this.app.auth.devices()) {
        this.app.db.run(
          'INSERT INTO push_queue(device_id,item_id,created_at) VALUES(?,?,?)',
          d.id,
          id,
          now,
        );
        void this.app.integrations.push
          .notifyOffline(d, item)
          .catch((e) => this.app.log.warn('push failed', String(e)));
      }
    }
    return item;
  }

  get(id: string): InboxItem | undefined {
    const r = this.app.db.get<Row>('SELECT * FROM inbox WHERE id=?', id);
    return r ? toItem(r) : undefined;
  }

  list(
    opts: { status?: InboxStatus | 'open'; limit?: number } = {},
  ): InboxItem[] {
    const status = opts.status ?? 'open';
    const where =
      status === 'open' ? "status IN ('pending','seen')" : 'status = ?';
    const rows = this.app.db.all<Row>(
      `SELECT * FROM inbox WHERE ${where} ORDER BY created_at DESC LIMIT ?`,
      ...(status === 'open' ? [] : [status]),
      opts.limit ?? 100,
    );
    return rows.map(toItem);
  }

  pending(): InboxItem[] {
    return this.app.db
      .all<Row>(
        "SELECT * FROM inbox WHERE status='pending' ORDER BY created_at DESC",
      )
      .map(toItem);
  }

  private setStatus(
    id: string,
    status: InboxStatus,
    onlyFrom: InboxStatus[],
  ): InboxItem | undefined {
    const cur = this.get(id);
    if (!cur || !onlyFrom.includes(cur.status)) return cur;
    this.app.db.run(
      'UPDATE inbox SET status=?, updated_at=? WHERE id=?',
      status,
      this.app.clock.now(),
      id,
    );
    const item = this.get(id)!;
    this.broadcastChange(item);
    return item;
  }
  private broadcastChange(item: InboxItem): void {
    const gone = item.status === 'dismissed' || item.status === 'expired';
    this.app.hub.broadcast({
      type: 'inbox',
      full: false,
      items: gone ? [] : [item],
      removedIds: gone ? [item.id] : [],
    });
  }

  markSeen(id: string): InboxItem | undefined {
    return this.setStatus(id, 'seen', ['pending']);
  }
  dismiss(id: string): InboxItem | undefined {
    return this.setStatus(id, 'dismissed', ['pending', 'seen']);
  }
  /** Used for undo of a dismissal. */
  restore(id: string): InboxItem | undefined {
    return this.setStatus(id, 'pending', ['dismissed']);
  }
  dismissAll(): string[] {
    const ids = this.list({ status: 'open', limit: 10_000 }).map((i) => i.id);
    for (const id of ids) this.dismiss(id);
    return ids;
  }
  /** Apply a phone-side event. */
  applyEvent(itemId: string, event: 'shown' | 'opened' | 'dismissed'): void {
    if (event === 'dismissed') this.dismiss(itemId);
    else this.markSeen(itemId);
  }

  sweepExpired(): string[] {
    const now = this.app.clock.now();
    const rows = this.app.db.all<{ id: string }>(
      "SELECT id FROM inbox WHERE status IN ('pending','seen') AND expires_at IS NOT NULL AND expires_at <= ?",
      now,
    );
    for (const r of rows) this.setStatus(r.id, 'expired', ['pending', 'seen']);
    return rows.map((r) => r.id);
  }

  full(): {
    type: 'inbox';
    full: true;
    items: InboxItem[];
    removedIds: string[];
  } {
    return {
      type: 'inbox',
      full: true,
      items: this.list({ status: 'open' }),
      removedIds: [],
    };
  }

  /** Items queued for `deviceId` while it was offline. Clears the queue. */
  drainPushQueue(deviceId: string): InboxItem[] {
    const rows = this.app.db.all<{ item_id: string }>(
      'SELECT item_id FROM push_queue WHERE device_id=? ORDER BY id',
      deviceId,
    );
    this.app.db.run('DELETE FROM push_queue WHERE device_id=?', deviceId);
    return rows
      .map((r) => this.get(r.item_id))
      .filter(
        (i): i is InboxItem =>
          !!i && (i.status === 'pending' || i.status === 'seen'),
      );
  }
  queueDepth(): number {
    return this.app.db.get<{ n: number }>(
      'SELECT COUNT(*) AS n FROM push_queue',
    )!.n;
  }
}
