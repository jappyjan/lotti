import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
  chmodSync,
} from 'node:fs';
import { join } from 'node:path';
import type { App } from './app.ts';
import { isoLocal } from './util/clock.ts';

export type FileKind = 'skill' | 'script';

export interface FileEntry {
  name: string;
  description: string;
  size: number;
  lastUsedAt: string | null;
  useCount: number;
  updatedAt: string;
}

const NAME_RE = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/;

/**
 * Skills (markdown how-tos the agent loads on demand) and scripts (executables the agent runs with `shell`),
 * stored as plain files in DATA_DIR/workspace/{skills,scripts}. "Last use" is tracked in the DB.
 */
export class SkillStore {
  constructor(private app: App) {}

  dir(kind: FileKind): string {
    return join(
      this.app.config.workspaceDir,
      kind === 'skill' ? 'skills' : 'scripts',
    );
  }
  ensureDirs(): void {
    mkdirSync(this.dir('skill'), { recursive: true });
    mkdirSync(this.dir('script'), { recursive: true });
  }
  private file(kind: FileKind, name: string): string {
    if (!NAME_RE.test(name))
      throw new Error(`Invalid name "${name}" (letters, digits, . _ - only).`);
    return join(
      this.dir(kind),
      kind === 'skill' && !name.endsWith('.md') ? name + '.md' : name,
    );
  }
  private bare(kind: FileKind, f: string): string {
    return kind === 'skill' ? f.replace(/\.md$/, '') : f;
  }

  list(kind: FileKind): FileEntry[] {
    this.ensureDirs();
    return readdirSync(this.dir(kind))
      .filter((f) => !f.startsWith('.'))
      .sort()
      .map((f) => {
        const name = this.bare(kind, f);
        const st = statSync(join(this.dir(kind), f));
        const u = this.app.db.get<{
          last_used_at: number | null;
          count: number;
        }>('SELECT * FROM usage WHERE kind=? AND name=?', kind, name);
        return {
          name,
          description: this.describe(kind, f),
          size: st.size,
          lastUsedAt: u?.last_used_at ? isoLocal(u.last_used_at) : null,
          useCount: u?.count ?? 0,
          updatedAt: isoLocal(st.mtimeMs),
        };
      });
  }

  private describe(kind: FileKind, f: string): string {
    try {
      const text = readFileSync(join(this.dir(kind), f), 'utf8');
      // SKILL.md frontmatter: `description:` wins over the first body line.
      const fm = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
      const d = fm && /^description:\s*(.+)$/im.exec(fm[1]!);
      if (d)
        return d[1]!
          .trim()
          .replace(/^["']|["']$/g, '')
          .slice(0, 140);
      const lines = (fm ? text.slice(fm[0].length) : text).split('\n');
      const l = lines
        .map((x) =>
          x.replace(/^(#!.*|#+\s*|\/\/\s*|description:\s*)/i, '').trim(),
        )
        .find((x) => x && !x.startsWith('---'));
      return (l ?? '').slice(0, 140);
    } catch {
      return '';
    }
  }

  get(
    kind: FileKind,
    name: string,
    opts: { markUsed?: boolean } = {},
  ): string | undefined {
    const f = this.file(kind, name);
    if (!existsSync(f)) return undefined;
    if (opts.markUsed) this.markUsed(kind, name);
    return readFileSync(f, 'utf8');
  }

  /** Returns the previous content (undefined if new). */
  put(kind: FileKind, name: string, content: string): string | undefined {
    this.ensureDirs();
    const f = this.file(kind, name);
    const prev = existsSync(f) ? readFileSync(f, 'utf8') : undefined;
    writeFileSync(f, content, 'utf8');
    if (kind === 'script') chmodSync(f, 0o755);
    return prev;
  }

  delete(kind: FileKind, name: string): string | undefined {
    const f = this.file(kind, name);
    if (!existsSync(f)) return undefined;
    const prev = readFileSync(f, 'utf8');
    rmSync(f);
    this.app.db.run('DELETE FROM usage WHERE kind=? AND name=?', kind, name);
    return prev;
  }

  markUsed(kind: FileKind, name: string): void {
    this.app.db.run(
      `INSERT INTO usage(kind,name,last_used_at,count) VALUES(?,?,?,1)
       ON CONFLICT(kind,name) DO UPDATE SET last_used_at=excluded.last_used_at, count=count+1`,
      kind,
      name,
      this.app.clock.now(),
    );
  }

  /** Called by the shell tool: mark scripts referenced in a command as used. */
  markScriptsInCommand(cmd: string): void {
    for (const s of this.list('script'))
      if (cmd.includes(s.name)) this.markUsed('script', s.name);
  }

  /** Compact index for the system prompt. */
  index(): string {
    return this.list('skill')
      .map((s) => `- ${s.name}: ${s.description}`)
      .join('\n');
  }
}
