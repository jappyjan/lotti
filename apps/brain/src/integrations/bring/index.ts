import type { App } from '../../app.ts';
import type {
  AccountConnector,
  AccountRow,
  ActionOutcome,
  BringClient,
} from '../index.ts';
import { BringApi, BringError, type BringSession } from './api.ts';

const DONE = {
  add: {
    de: (n: string) => `${n} hinzugefügt`,
    en: (n: string) => `${n} added`,
  },
  remove: {
    de: (n: string) => `${n} abgehakt`,
    en: (n: string) => `${n} checked off`,
  },
};

/** Bring! integration: login from the `bring` account's secrets (email, password); session cached, re-login on 401. */
export class BringHttp implements BringClient {
  private api: BringApi;
  private session?: BringSession;
  constructor(private app: App) {
    this.api = new BringApi((...a) => app.fetch(...a));
  }

  private account():
    { id: string; email: string; password: string } | undefined {
    const r = this.app.db.get<{ id: string }>(
      "SELECT id FROM accounts WHERE kind='bring' ORDER BY created_at LIMIT 1",
    );
    if (!r) return undefined;
    const email = this.app.secrets.get(`account.${r.id}.email`);
    const password = this.app.secrets.get(`account.${r.id}.password`);
    return email && password ? { id: r.id, email, password } : undefined;
  }

  private async login(): Promise<BringSession> {
    const a = this.account();
    if (!a)
      throw new BringError(
        'Bring! is not set up: enter your Bring! email and password in the app.',
      );
    this.session = await this.api.login(a.email, a.password);
    return this.session;
  }

  /** Run with the cached session; on an expired session log in again once. */
  private async withSession<T>(f: (s: BringSession) => Promise<T>): Promise<T> {
    const s = this.session ?? (await this.login());
    try {
      const r = await f(s);
      this.touch();
      return r;
    } catch (e) {
      if (e instanceof BringError && e.status === 401) {
        const r = await f(await this.login());
        this.touch();
        return r;
      }
      throw e;
    }
  }

  private touch(): void {
    const a = this.account();
    if (a)
      this.app.db.run(
        "UPDATE accounts SET last_sync_at=?, status='ok', last_error=NULL WHERE id=?",
        this.app.clock.now(),
        a.id,
      );
  }

  private listId(s: BringSession, listId?: string): string {
    const id =
      listId ||
      this.app.settings.str('bring.default_list') ||
      s.defaultListUuid;
    if (!id) throw new BringError('No Bring! list found.');
    return id;
  }

  lists() {
    return this.withSession((s) => this.api.lists(s));
  }
  items(listId?: string) {
    return this.withSession((s) => this.api.items(s, this.listId(s, listId)));
  }
  recent(listId?: string) {
    return this.withSession((s) => this.api.recent(s, this.listId(s, listId)));
  }

  async add(
    item: string,
    spec?: string,
    listId?: string,
    locale: 'de' | 'en' = 'de',
  ): Promise<ActionOutcome> {
    await this.withSession((s) =>
      this.api.add(s, this.listId(s, listId), item, spec),
    );
    return {
      ok: true,
      text: `${DONE.add[locale](spec ? `${item} (${spec})` : item)}`,
    };
  }

  async remove(
    item: string,
    listId?: string,
    locale: 'de' | 'en' = 'de',
  ): Promise<ActionOutcome> {
    await this.withSession((s) =>
      this.api.complete(s, this.listId(s, listId), item),
    );
    return { ok: true, text: DONE.remove[locale](item) };
  }

  async status() {
    const a = this.account();
    if (!a) return { connected: false, error: 'No login stored yet.' };
    try {
      const s = await this.login();
      return {
        connected: true,
        account: s.name,
        defaultList:
          this.app.settings.str('bring.default_list') ||
          s.defaultListUuid ||
          null,
      };
    } catch (e) {
      return {
        connected: false,
        error: e instanceof Error ? e.message : String(e),
      };
    }
  }
}

export const bringConnector: AccountConnector = {
  kind: 'bring',
  async check(acc: AccountRow, app: App) {
    const email = app.secrets.get(`account.${acc.id}.email`);
    const password = app.secrets.get(`account.${acc.id}.password`);
    if (!email || !password)
      return {
        ok: false,
        status: 'not_connected',
        error: 'Email or password missing.',
      };
    try {
      await new BringApi((...a) => app.fetch(...a)).login(email, password);
      return { ok: true, status: 'ok' };
    } catch (e) {
      return {
        ok: false,
        status: 'error',
        error: e instanceof Error ? e.message : String(e),
      };
    }
  },
};
