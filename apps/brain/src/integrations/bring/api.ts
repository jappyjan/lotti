/**
 * Isolated client for the UNOFFICIAL Bring! REST API (what the Bring! apps use).
 * It may change without notice; every failure is turned into a clear `BringError`.
 * Nothing else in the backend knows these URLs.
 */
const BASE = 'https://api.getbring.com/rest/v2/';
// Public key shipped with the Bring! web/Android client.
const API_KEY = 'cof4Nc6D8saplXjE3h3HXqHH8m7VU2i1Gs0g85Sp';

export class BringError extends Error {
  constructor(
    message: string,
    public status?: number,
  ) {
    super(message);
  }
}

export interface BringSession {
  uuid: string;
  token: string;
  name: string;
  defaultListUuid: string;
}

export interface BringItem {
  name: string;
  spec?: string;
}

export class BringApi {
  constructor(private fetchFn: typeof fetch) {}

  private headers(token?: string): Record<string, string> {
    return {
      'X-BRING-API-KEY': API_KEY,
      'X-BRING-CLIENT': 'webApp',
      'X-BRING-APPLICATION': 'bring',
      'X-BRING-COUNTRY': 'DE',
      accept: 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    };
  }

  private async call(
    method: string,
    path: string,
    opts: { token?: string; form?: Record<string, string> } = {},
  ): Promise<any> {
    let res: Response;
    try {
      res = await this.fetchFn(BASE + path, {
        method,
        headers: {
          ...this.headers(opts.token),
          ...(opts.form
            ? { 'content-type': 'application/x-www-form-urlencoded' }
            : {}),
        },
        ...(opts.form
          ? { body: new URLSearchParams(opts.form).toString() }
          : {}),
        signal: AbortSignal.timeout(15_000),
      });
    } catch (e) {
      throw new BringError(
        `Bring! is not reachable: ${e instanceof Error ? e.message : e}`,
      );
    }
    const text = await res.text();
    if (!res.ok) {
      if (res.status === 401 || res.status === 403)
        throw new BringError(
          path === 'bringauth'
            ? 'Bring! login failed: wrong email or password.'
            : 'Bring! session expired.',
          res.status,
        );
      throw new BringError(
        `Bring! answered HTTP ${res.status}${text ? ': ' + text.slice(0, 200) : ''}`,
        res.status,
      );
    }
    if (!text) return {};
    try {
      return JSON.parse(text);
    } catch {
      throw new BringError('Bring! sent a response that is not JSON.');
    }
  }

  async login(email: string, password: string): Promise<BringSession> {
    const j = await this.call('POST', 'bringauth', {
      form: { email, password },
    });
    if (!j.uuid || !j.access_token)
      throw new BringError('Bring! login returned no session.');
    return {
      uuid: j.uuid,
      token: j.access_token,
      name: j.name ?? email,
      defaultListUuid: j.bringListUUID ?? '',
    };
  }

  async lists(s: BringSession): Promise<{ id: string; name: string }[]> {
    const j = await this.call('GET', `bringusers/${s.uuid}/lists`, {
      token: s.token,
    });
    return (j.lists ?? []).map((l: any) => ({
      id: String(l.listUuid),
      name: String(l.name),
    }));
  }

  private async raw(s: BringSession, listId: string) {
    return this.call('GET', `bringlists/${listId}`, { token: s.token });
  }

  async items(s: BringSession, listId: string): Promise<BringItem[]> {
    const j = await this.raw(s, listId);
    return (j.items?.purchase ?? j.purchase ?? []).map(toItem);
  }

  async recent(s: BringSession, listId: string): Promise<BringItem[]> {
    const j = await this.raw(s, listId);
    return (j.items?.recently ?? j.recently ?? []).map(toItem);
  }

  private change(
    s: BringSession,
    listId: string,
    f: Record<string, string>,
  ): Promise<unknown> {
    return this.call('PUT', `bringlists/${listId}`, {
      token: s.token,
      form: {
        purchase: '',
        recently: '',
        specification: '',
        remove: '',
        sender: 'null',
        ...f,
      },
    });
  }

  add(s: BringSession, listId: string, name: string, spec = '') {
    return this.change(s, listId, { purchase: name, specification: spec });
  }
  /** Check an item off (it moves to "recently used"), like ticking it in the app. */
  complete(s: BringSession, listId: string, name: string) {
    return this.change(s, listId, { recently: name });
  }
}

const toItem = (i: any): BringItem => ({
  name: String(i.name),
  ...(i.specification ? { spec: String(i.specification) } : {}),
});
