import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { makeApp } from '../testing/helpers.ts';
import { ClaudeRuntime } from './runtimes/claude.ts';
import { CodexRuntime, parseDeviceAuth } from './runtimes/codex.ts';
import { registerIntegrations } from './register.ts';
import { runAgent } from '../agent/loop.ts';
import { newRun } from '../tools/registry.ts';

const fakeBin = (name: string, body: string) => {
  const dir = mkdtempSync(join(tmpdir(), 'fake-cli-'));
  const f = join(dir, name);
  writeFileSync(
    f,
    `#!${process.execPath}\nconst fs=require('fs');const path=require('path');const LOG=path.join(__dirname,'log.json');\n${body}`,
  );
  chmodSync(f, 0o755);
  return {
    bin: f,
    log: () => JSON.parse(readFileSync(join(dir, 'log.json'), 'utf8')),
  };
};

const CODEX = `
const a=process.argv.slice(2);
const home=process.env.CODEX_HOME;
if(a.includes('status')){ process.exit(fs.existsSync(path.join(home,'auth.json'))?0:1); }
if(a.includes('--device-auth')){
  console.log('Welcome to Codex [v\\x1b[90m0.1.2\\x1b[0m]\\n\\n1. Open this link\\n   \\x1b[94mhttps://auth.openai.com/codex/device\\x1b[0m\\n\\n2. Enter this one-time code \\x1b[90m(expires in 15 minutes)\\x1b[0m\\n   \\x1b[94mAB12-CD345\\x1b[0m\\n');
  setTimeout(()=>{ if(!process.env.FAIL_LOGIN){fs.writeFileSync(path.join(home,'auth.json'),'{}');} process.exit(process.env.FAIL_LOGIN?1:0); },300);
} else if(a[0]==='exec'){
  let stdin='';process.stdin.on('data',d=>stdin+=d).on('end',()=>{
    fs.writeFileSync(LOG,JSON.stringify({args:a,stdin,env:{home,token:process.env.LOTTI_TOOLS_TOKEN,master:process.env.MASTER_KEY||null,cwd:process.cwd()}}));
    fs.writeFileSync(a[a.indexOf('-o')+1],'{"text":"Hallo vom Codex","followUps":[]}');
  });
} else if(a[0]==='logout'){ try{fs.unlinkSync(path.join(home,'auth.json'))}catch{} }
`;

test('codex: parse device-auth output (ANSI, version number is not the code)', () => {
  const raw =
    'Welcome to Codex [v\u001b[90m0.162.1\u001b[0m]\n\n1. Open this link\n   \u001b[94mhttps://auth.openai.com/codex/device\u001b[0m\n\n2. Enter this one-time code \u001b[90m(expires in 15 minutes)\u001b[0m\n   \u001b[94mXK32-HS4SR\u001b[0m\n';
  assert.deepEqual(parseDeviceAuth(raw), {
    url: 'https://auth.openai.com/codex/device',
    code: 'XK32-HS4SR',
  });
  assert.deepEqual(parseDeviceAuth('nothing yet'), {});
});

test('codex: device login via ops (start -> url+code, status -> done), state under DATA_DIR/codex', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const f = fakeBin('codex', CODEX);
  const codex = new CodexRuntime(t.app, f.bin);
  t.app.providers.register(codex);
  assert.equal(codex.configured(), false);
  assert.ok(codex.home.startsWith(t.app.config.dataDir));

  const s = (await t.app.ops.invoke(
    'providers.codex_login_start',
    {},
    'app',
  )) as any;
  assert.equal(s.result.state, 'pending');
  assert.equal(s.result.url, 'https://auth.openai.com/codex/device');
  assert.equal(s.result.code, 'AB12-CD345');
  const mid = (await t.app.ops.invoke(
    'providers.codex_login_status',
    {},
    'app',
  )) as any;
  assert.equal(mid.result.loggedIn, false);
  assert.equal(mid.result.state, 'pending');
  await new Promise((r) => setTimeout(r, 600));
  const done = (await t.app.ops.invoke(
    'providers.codex_login_status',
    {},
    'app',
  )) as any;
  assert.equal(done.result.state, 'done');
  assert.equal(done.result.loggedIn, true);
  assert.equal(codex.configured(), true);
  const st = (
    (await t.app.ops.invoke(
      'providers.status',
      { provider: 'codex' },
      'app',
    )) as any
  ).result;
  assert.equal(st.configured, true);
  assert.equal(st.kind, 'agent-runtime');
  assert.match(
    (
      (await t.app.ops.invoke(
        'providers.codex_login_start',
        {},
        'agent',
      )) as any
    ).error,
    /only available in the app/,
  );
  await t.app.ops.invoke('providers.codex_logout', {}, 'app');
  assert.equal(codex.configured(), false);
});

test('codex: failed login reports an error', async () => {
  const t = makeApp();
  const f = fakeBin(
    'codex',
    CODEX.replaceAll('process.env.FAIL_LOGIN', 'true'),
  );
  const codex = new CodexRuntime(t.app, f.bin);
  const s = await codex.loginStart();
  assert.equal(s.code, 'AB12-CD345');
  await new Promise((r) => setTimeout(r, 600));
  const st = await codex.loginStatus();
  assert.equal(st.state, 'error');
  assert.equal(st.loggedIn, false);
});

test('codex: missing binary is a clear error', async () => {
  const t = makeApp();
  const codex = new CodexRuntime(t.app, '/nonexistent/codex');
  const s = await codex.loginStart(2000);
  assert.equal(s.state, 'error');
  assert.match(s.error!, /Cannot run/);
});

test('codex: run without login is a clear error', async () => {
  const t = makeApp();
  const codex = new CodexRuntime(t.app, fakeBin('codex', CODEX).bin);
  await assert.rejects(
    codex.run({ system: 's', prompt: 'p', mcpServers: [] }),
    /not signed in/,
  );
});

test('codex: run end to end through the agent loop (active provider = codex)', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const f = fakeBin('codex', CODEX);
  const codex = new CodexRuntime(t.app, f.bin);
  t.app.providers.register(codex);
  await codex.loginStart();
  await new Promise((r) => setTimeout(r, 600));
  assert.ok(codex.configured());
  t.app.settings.set('provider.active', 'codex');
  const run = newRun({ askId: 'ask_1' });
  const a = await runAgent(t.app, {
    system: 'SYS',
    history: [{ role: 'user', content: 'Wie spät?' }],
    run,
  });
  assert.equal(a.text, 'Hallo vom Codex');
  const log = f.log();
  assert.equal(log.args[0], 'exec');
  assert.ok(
    log.args.some(
      (x: string) =>
        x.startsWith('mcp_servers.lotti.url="http://127.0.0.1:') &&
        x.endsWith('/mcp/tools"'),
    ),
  );
  assert.ok(
    log.args.includes(
      'mcp_servers.lotti.bearer_token_env_var="LOTTI_TOOLS_TOKEN"',
    ),
  );
  assert.ok(
    log.args.includes('mcp_servers.lotti.http_headers={"X-Lotti-Ask"="ask_1"}'),
  );
  assert.equal(log.env.token, t.app.auth.internalToken());
  assert.equal(log.env.master, null);
  assert.equal(log.env.home, codex.home);
  assert.match(log.stdin, /SYS[\s\S]*User: Wie spät\?/);
  assert.equal(
    log.env.cwd.replace(/^\/private/, ''),
    t.app.config.workspaceDir.replace(/^\/private/, ''),
  );
});

const CLAUDE = `
let stdin='';process.stdin.on('data',d=>stdin+=d).on('end',()=>{
  fs.writeFileSync(LOG,JSON.stringify({args:process.argv.slice(2),stdin,env:{token:process.env.CLAUDE_CODE_OAUTH_TOKEN,master:process.env.MASTER_KEY||null,dir:process.env.CLAUDE_CONFIG_DIR}}));
  if(process.env.FAIL_CLAUDE){console.error('auth expired');process.exit(1);}
  console.log('Antwort von Claude');
});
`;

test('claude: token credential makes it configured; run passes token, MCP config, no builtin tools', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const f = fakeBin('claude', CLAUDE);
  t.app.providers.register(new ClaudeRuntime(t.app, f.bin));
  assert.equal(
    (
      (await t.app.ops.invoke(
        'providers.status',
        { provider: 'claude_code' },
        'app',
      )) as any
    ).result.configured,
    false,
  );
  await t.app.ops.invoke(
    'providers.set_credential',
    { provider: 'claude_code', apiKey: 'sk-ant-oat-xyz' },
    'app',
  );
  assert.equal(
    (
      (await t.app.ops.invoke(
        'providers.status',
        { provider: 'claude_code' },
        'app',
      )) as any
    ).result.configured,
    true,
  );
  t.app.settings.set('provider.active', 'claude_code');
  const run = newRun({ askId: 'ask_9' });
  const a = await runAgent(t.app, {
    system: 'SYS',
    history: [{ role: 'user', content: 'Hi' }],
    run,
  });
  assert.equal(a.text, 'Antwort von Claude');
  const log = f.log();
  assert.equal(log.env.token, 'sk-ant-oat-xyz');
  assert.equal(log.env.master, null);
  assert.ok(log.env.dir.startsWith(t.app.config.dataDir));
  assert.ok(log.args.includes('-p'));
  assert.equal(log.args[log.args.indexOf('--tools') + 1], '');
  assert.equal(log.args[log.args.indexOf('--system-prompt') + 1], 'SYS');
  assert.ok(log.args.includes('--strict-mcp-config'));
  const cfg = JSON.parse(log.args[log.args.indexOf('--mcp-config') + 1]);
  assert.equal(cfg.mcpServers.lotti.type, 'http');
  assert.match(cfg.mcpServers.lotti.url, /\/mcp\/tools$/);
  assert.equal(
    cfg.mcpServers.lotti.headers.authorization,
    `Bearer ${t.app.auth.internalToken()}`,
  );
  assert.equal(cfg.mcpServers.lotti.headers['x-lotti-ask'], 'ask_9');
  assert.match(log.stdin, /User: Hi/);
});

test('claude: failure surfaces stderr; falls back when a fallback provider exists', async () => {
  const t = makeApp();
  const f = fakeBin(
    'claude',
    CLAUDE.replace('process.env.FAIL_CLAUDE', 'true'),
  );
  const c = new ClaudeRuntime(t.app, f.bin);
  t.app.secrets.set('provider.claude_code.api_key', 'tok');
  await assert.rejects(
    c.run({ system: 's', prompt: 'p', mcpServers: [] }),
    /auth expired/,
  );
  await assert.rejects(
    new ClaudeRuntime(makeApp().app).run({
      system: '',
      prompt: '',
      mcpServers: [],
    }),
    /setup-token/,
  );
});
