import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink, open } from 'node:fs/promises';
import { createServer } from 'node:net';
import { createServer as createHttpServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';
import { stripVTControlCharacters } from 'node:util';
import { provider } from './fixtures/pi-runtime/provider.mjs';
import { responseProxy } from './fixtures/pi-runtime/proxy.mjs';
import { remainingScenarios, platformGates, consumerGates } from './fixtures/pi-runtime/scenarios.mjs';

const fixtures = join(dirname(fileURLToPath(import.meta.url)), 'fixtures/pi-runtime');
const artifact = name => {
  const value = process.env[name];
  assert.ok(value?.startsWith('/nix/store/'), `${name} must name an explicit Nix artifact, not a PATH launcher`);
  return value;
};
const piPackage = artifact('PI_AGENT_BUS_TEST_PI_PACKAGE');
const extensionPackage = artifact('PI_AGENT_BUS_TEST_EXTENSION_PACKAGE');
const hubExecutable = artifact('PI_AGENT_BUS_TEST_EXECUTABLE');
const python = artifact('PI_AGENT_BUS_TEST_PYTHON');
const toolPath = process.env.PI_AGENT_BUS_TEST_TOOL_PATH;
assert.ok(toolPath && toolPath.split(':').every(path => /^\/nix\/store\/[^/]+\/bin$/.test(path)), 'explicit Nix fd/ripgrep path prevents Pi bootstrap downloads');
const piDir = join(piPackage, 'libexec/pi');
const piExecutable = join(piDir, 'pi');
const token = 'synthetic-runtime-fixture-token-not-a-secret';

async function waitFor(fn, description, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const value = await fn();
    if (value) return value;
    await delay(25);
  }
  assert.fail(`deadline: ${description}`);
}
async function port() {
  const server = createServer();
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const value = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return value;
}
function cleanEnv(home) {
  return { HOME: home, TMPDIR: home, XDG_CONFIG_HOME: join(home, 'config'),
    XDG_CACHE_HOME: join(home, 'cache'), XDG_DATA_HOME: join(home, 'data'),
    XDG_STATE_HOME: join(home, 'state'), TERM: 'xterm-256color', LANG: 'C.UTF-8',
    PATH: toolPath, PI_PACKAGE_DIR: piDir, PI_SKIP_VERSION_CHECK: '1', PI_TELEMETRY: '0' };
}
async function bounded(promise, ms, message) {
  let timer;
  try { return await Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(Error(message)), ms); })]); }
  finally { clearTimeout(timer); }
}
async function stopChild(child, closed) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  const timer = setTimeout(() => child.kill('SIGKILL'), 3000);
  try { await bounded(closed, 6000, 'child cleanup deadline'); }
  finally { clearTimeout(timer); }
}
async function setup(t) {
  const home = await mkdtemp(join(tmpdir(), 'switchboard-pi-'));
  const cleanup = [];
  t.after(async () => {
    const failures = [];
    for (const close of cleanup.reverse()) {
      try { await close(); } catch (error) { failures.push(error); }
    }
    await rm(home, { recursive: true, force: true });
    if (failures.length) throw new AggregateError(failures, 'fixture cleanup failed');
  });
  const modelProvider = await provider(); cleanup.push(() => modelProvider.close());
  const hubPort = await port();
  const url = `http://127.0.0.1:${hubPort}`;
  const tokenFile = join(home, 'token'); await writeFile(tokenFile, token, { mode: 0o600 });
  const hub = spawn(hubExecutable, [], { cwd: home, env: { ...cleanEnv(home),
    PI_AGENT_BUS_BIND_HOST: '127.0.0.1', PI_AGENT_BUS_PORT: String(hubPort), PI_AGENT_BUS_TOKEN_FILE: tokenFile,
  }, stdio: ['ignore', 'ignore', 'pipe'] });
  let hubErrors = '';
  hub.stderr.on('data', data => { hubErrors = (hubErrors + data).slice(-16000); });
  const hubClosed = once(hub, 'close'); cleanup.push(() => stopChild(hub, hubClosed));
  async function request(path, method = 'GET', body) {
    return fetch(url + path, { method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(2000) });
  }
  await waitFor(async () => {
    assert.equal(hub.exitCode, null, `compiled hub exited: ${hubErrors}`);
    try { return (await request('/health')).ok; } catch { return false; }
  }, 'compiled hub health');
  async function agents() {
    const response = await request('/v1/agents'); assert.equal(response.status, 200);
    return (await response.json()).agents;
  }
  const sender = randomUUID();
  const registerSender = async () => {
    const response = await request(`/v1/agents/${sender}`, 'PUT', { agentId: sender, sessionId: randomUUID(),
      host: 'fixture-peer', cwd: '/fixture', label: 'fixture-peer', sessionName: 'fixture-peer',
      model: null, status: 'idle', pid: 1, acceptsControl: false });
    assert.equal(response.status, 204);
  };
  async function send(to, kind, body) {
    await registerSender();
    const response = await request('/v1/messages', 'POST', { id: randomUUID(), from: sender, to, kind, body });
    return { status: response.status, body: await response.json() };
  }
  let count = 0;
  async function launch({ env: extraEnv = {}, args = [], session, settings = {} } = {}) {
    const root = join(home, `pi-${++count}`); const agentDir = join(root, 'agent');
    const cwd = join(root, 'cwd'); const eventsFile = join(root, 'events.jsonl'); const controlFile = join(root, 'control.json');
    await mkdir(join(agentDir, 'extensions'), { recursive: true }); await mkdir(cwd);
    await mkdir(join(root, 'sessions')); await writeFile(eventsFile, ''); await writeFile(controlFile, '{}');
    await symlink(extensionPackage, join(agentDir, 'extensions/switchboard'));
    await writeFile(join(agentDir, 'extensions/discovery-sentinel.js'), `
      import { appendFileSync } from 'node:fs';
      export default function(pi) {
        pi.on('session_start', () => appendFileSync(process.env.SWITCHBOARD_FIXTURE_EVENTS,
          JSON.stringify({type: 'discovery_sentinel'}) + '\\n'));
      }
    `);
    await symlink(join(fixtures, 'observer.js'), join(agentDir, 'extensions/observer.js'));
    await writeFile(join(agentDir, 'settings.json'), JSON.stringify({
      defaultProvider: 'fixture', defaultModel: 'fixture-a', defaultThinkingLevel: 'off',
      enableInstallTelemetry: false, enableAnalytics: false, lastChangelogVersion: '0.85.1',
      retry: { enabled: false, provider: { maxRetries: 0, timeoutMs: 10000 } },
      compaction: { enabled: false }, branchSummary: { skipPrompt: true }, ...settings,
    }));
    await writeFile(join(agentDir, 'models.json'), JSON.stringify({ providers: { fixture: {
      baseUrl: modelProvider.url, api: 'openai-completions', apiKey: 'synthetic-provider-key',
      models: ['fixture-a', 'qwen-fixture'].map(id => ({ id, contextWindow: 128000, maxTokens: 1024 })),
    } } }));
    const childEnv = { ...cleanEnv(root), PI_CODING_AGENT_DIR: agentDir,
      PI_CODING_AGENT_SESSION_DIR: join(root, 'sessions'), PI_AGENT_BUS_URL: url, PI_AGENT_BUS_TOKEN: token,
      SWITCHBOARD_FIXTURE_EVENTS: eventsFile, SWITCHBOARD_FIXTURE_CONTROL: controlFile, ...extraEnv };
    const child = spawn(python, ['-I', join(fixtures, 'pty-driver.py')], {
      cwd: root, env: cleanEnv(root), stdio: ['pipe', 'pipe', 'pipe'],
    });
    const closed = once(child, 'close');
    let terminal = ''; let terminalWritten = 0; let protocol = ''; let errors = ''; let exit;
    child.stderr.on('data', data => { errors = (errors + data).slice(-16000); });
    child.stdin.on('error', error => { if (error.code !== 'EPIPE') errors += String(error); });
    child.stdout.on('data', data => {
      protocol += data;
      assert.ok(protocol.length <= 2 * 1024 * 1024, 'bounded bridge output');
      let newline;
      while ((newline = protocol.indexOf('\n')) >= 0) {
        const record = JSON.parse(protocol.slice(0, newline)); protocol = protocol.slice(newline + 1);
        if (record.type === 'output') {
          const text = Buffer.from(record.data, 'base64').toString();
          terminalWritten += text.length;
          terminal = (terminal + text).slice(-131072);
        }
        if (record.type === 'exit') exit = record.code;
      }
    });
    const command = value => child.stdin.write(JSON.stringify(value) + '\n');
    command({ op: 'start', argv: [piExecutable, '--no-context-files', '--no-skills', '--no-prompt-templates',
      '--no-builtin-tools', '--no-approve', ...(session ? ['--session', session] : []), ...args],
      cwd, env: childEnv, rows: 32, cols: 120 });
    const stop = async () => {
      if (child.exitCode !== null || child.signalCode !== null) return;
      if (exit === undefined) command({ op: 'terminate' });
      child.stdin.end();
      await bounded(closed, 7000, 'PTY helper did not reap child');
      assert.equal(child.exitCode, 0, errors);
    };
    cleanup.push(async () => {
      await stop();
      assert.ok(!/not found\. Downloading/.test(terminal), 'fixture must supply tools without bootstrap download attempts');
    });
    const events = async () => (await readFile(eventsFile, 'utf8')).split('\n').filter(Boolean).map(line => JSON.parse(line));
    const input = text => command({ op: 'input', data: Buffer.from(text).toString('base64') });
    const submit = async text => {
      input(text); await delay(100);
      // Argument completion consumes Enter. Dismiss it before submitting bus commands.
      if (text.startsWith('/bus ')) { input('\x1b'); await delay(100); }
      input('\r');
    };
    const event = async (type, predicate = () => true) => waitFor(async () => {
      const observed = (await events()).find(e => e.type === type && predicate(e));
      if (observed) return observed;
      assert.equal(exit, undefined, `Pi exited before ${type}: ${terminal}\n${errors}`);
      return undefined;
    }, type).catch(async error => {
      throw new Error(`${error.message}\nterminal: ${JSON.stringify(stripVTControlCharacters(terminal).slice(-8000))}\nevents: ${(await events()).map(e => `${e.type}:${e.reason ?? ''}`).join(', ')}`);
    });
    const started = await event('session_start');
    // session_start precedes input reader setup. A rendered footer proves TUI startup.
    if (started.mode === 'tui') await waitFor(() => terminal.includes('fixture-a'), 'rendered TUI footer');
    return { root, cwd, events, event, input, submit, stop, started, terminal: () => terminal,
      terminalOffset: () => terminalWritten,
      terminalSince: offset => terminal.slice(Math.max(0, offset - (terminalWritten - terminal.length))),
      quit: async () => { await submit('/quit'); await event('session_shutdown', e => e.reason === 'quit'); await bounded(closed, 7000, 'Pi quit deadline'); },
      control: value => writeFile(controlFile, JSON.stringify(value)),
      releaseInput: () => writeFile(controlFile + '.release', ''),
      resize: () => command({ op: 'resize', rows: 40, cols: 100 }),
    };
  }
  return { home, launch, agents, send, modelProvider, sender,
    proxy: async () => {
      const proxy = await responseProxy(url); cleanup.push(() => proxy.close()); return proxy;
    },
    disconnectHub: () => stopChild(hub, hubClosed),
    receiving: async cwd => waitFor(async () => (await agents()).find(a => a.cwd === cwd && a.receiving), 'actual client registration and receiving'),
  };
}

// This check intentionally fails on missing artifacts or behavior. It never
// treats exit zero, a mocked lifecycle callback, or an excluded test as acceptance.
test('raw Pi artifact is the pinned native 0.85.1 binary', async t => {
  t.diagnostic(`Missing standalone behavioral scenarios: ${remainingScenarios.join('; ') || 'none in the agreed matrix; native abort boundaries do not replace uncooperative-callback unit evidence'}`);
  t.diagnostic(`Platform execution gates: ${platformGates.join('; ')}`);
  t.diagnostic(`Consumer composition/deployment gates: ${consumerGates.join('; ')}`);
  const handle = await open(piExecutable, 'r');
  const magic = Buffer.alloc(4);
  try { await handle.read(magic, 0, 4, 0); } finally { await handle.close(); }
  assert.ok(['7f454c46', 'cffaedfe', 'feedfacf', 'cafebabe'].includes(magic.toString('hex')), 'reject shell/Node/credential wrappers');
  const manifest = JSON.parse(await readFile(join(piDir, 'package.json'), 'utf8'));
  assert.equal(manifest.version, '0.85.1');
  const home = await mkdtemp(join(tmpdir(), 'pi-version-'));
  try { assert.equal(execFileSync(piExecutable, ['--version'], { env: cleanEnv(home), cwd: home, timeout: 10000 }).toString().trim(), '0.85.1'); }
  finally { await rm(home, { recursive: true, force: true }); }
});

test('PTY bridge provides a controlling terminal and reaps its child on orchestrator EOF', { timeout: 15000 }, async () => {
  const home = await mkdtemp(join(tmpdir(), 'pi-pty-'));
  const child = spawn(python, ['-I', join(fixtures, 'pty-driver.py')], { env: cleanEnv(home), cwd: home, stdio: ['pipe', 'pipe', 'pipe'] });
  const closed = once(child, 'close');
  let output = ''; let errors = '';
  child.stdout.on('data', chunk => { output += chunk; assert.ok(output.length < 1048576); });
  child.stderr.on('data', chunk => { errors += chunk; });
  try {
    child.stdin.write(JSON.stringify({ op: 'start', argv: [python, '-I', '-c',
      'import os,time; print("TTY=" + str(os.isatty(0)) + ":" + str(os.tcgetpgrp(0)==os.getpgrp()), flush=True); time.sleep(60)'],
      cwd: home, env: cleanEnv(home), rows: 32, cols: 120 }) + '\n');
    await waitFor(() => output.split('\n').slice(0, -1).filter(Boolean).some(line => {
      const record = JSON.parse(line);
      return record.type === 'output' && Buffer.from(record.data, 'base64').toString().includes('TTY=True:True');
    }), 'controlling terminal', 5000);
    child.stdin.end();
    await bounded(closed, 7000, 'PTY EOF cleanup deadline');
    assert.equal(child.exitCode, 0, errors);
    const records = output.trim().split('\n').map(JSON.parse);
    const pid = records.find(e => e.type === 'started').pid;
    assert.ok(records.some(e => e.type === 'exit' && e.code < 0), 'reaped signalled child status');
    assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  } finally { await stopChild(child, closed); await rm(home, { recursive: true, force: true }); }
});

test('packaged TUI receives notices without turns, viewer is read-only, control defaults off', { timeout: 60000 }, async t => {
  const f = await setup(t); const pi = await f.launch(); const agent = await f.receiving(pi.cwd);
  assert.equal(agent.acceptsControl, false); assert.equal(agent.status, 'idle');
  assert.ok((await pi.events()).some(e => e.type === 'discovery_sentinel'), 'normal discovery loads the sentinel');
  assert.deepEqual(agent.model, { provider: 'fixture', id: 'fixture-a' });
  const notice = 'synthetic notice context marker';
  assert.equal((await f.send(agent.agentId, 'notice', notice)).status, 202);
  await waitFor(() => pi.terminal().includes('mail'), 'visible mail arrival');
  assert.equal(f.modelProvider.requests.length, 0);
  const blocked = await f.send(agent.agentId, 'prompt', '/bus control on');
  assert.equal(blocked.status, 403);
  assert.equal(blocked.body.error.code, 'control_disabled');
  await pi.submit('/bus inbox');
  await waitFor(() => pi.terminal().includes('Inbox (read only)'), 'read-only inbox list');
  pi.input('\r');
  await waitFor(() => pi.terminal().includes(notice), 'full notice in read-only viewer');
  pi.resize(); pi.input('/bus control on'); await delay(200); pi.input('\x1b'); await delay(200); pi.input('\x1b'); await delay(200);
  assert.equal(f.modelProvider.requests.length, 0);
  assert.equal((await f.receiving(pi.cwd)).acceptsControl, false);
  await pi.submit('local first prompt');
  await pi.event('agent_settled');
  assert.equal(f.modelProvider.requests.length, 1);
  assert.ok(JSON.stringify(f.modelProvider.requests[0].messages).includes(notice), 'viewing does not consume pending context');
  await pi.quit();
  await waitFor(async () => !(await f.agents()).some(a => a.agentId === agent.agentId), 'shutdown unregister');
  assert.deepEqual(f.modelProvider.errors, []);
});

async function freshTerminal(pi, action, text) {
  const before = pi.terminalOffset();
  await action();
  await waitFor(() => stripVTControlCharacters(pi.terminalSince(before)).includes(text), `fresh terminal: ${text}`).catch(error => {
    throw new Error(`${error.message}\nterminal: ${JSON.stringify(stripVTControlCharacters(pi.terminal()).slice(-8000))}`);
  });
}
async function closeInbox(pi) {
  pi.input('\x1b'); await delay(150); // Body to list.
  pi.input('\x1b'); await delay(150); // List to editor.
}

test('busy and disconnected TUI inbox opening changes human-read only', { timeout: 60000 }, async t => {
  const f = await setup(t); const pi = await f.launch(); const agent = await f.receiving(pi.cwd);
  f.modelProvider.scripts.push({ hold: true });
  await pi.submit('held busy viewer turn');
  await waitFor(() => f.modelProvider.heldCount === 1, 'busy provider held');
  const notice = 'busy disconnected pending notice marker';
  assert.equal((await f.send(agent.agentId, 'notice', notice)).status, 202);
  await waitFor(() => pi.terminal().includes('1 unread'), 'notice received while busy');
  await freshTerminal(pi, () => pi.submit('/bus inbox'), 'unread notice');
  await freshTerminal(pi, () => pi.input('\r'), notice);
  await freshTerminal(pi, () => pi.input('\x1b'), 'read notice');
  pi.input('\x1b'); await delay(150);
  assert.equal(f.modelProvider.requests.length, 1);
  assert.equal(f.modelProvider.heldCount, 1);
  assert.equal((await pi.events()).filter(e => e.type === 'agent_start').length, 1);
  assert.ok(!JSON.stringify(f.modelProvider.requests[0].messages).includes(notice));
  await f.disconnectHub();
  await waitFor(() => /connection (down|degraded)/.test(stripVTControlCharacters(pi.terminal())), 'actual relay disconnection visible');
  await freshTerminal(pi, () => pi.submit('/bus inbox'), 'read notice');
  await freshTerminal(pi, () => pi.input('\r'), notice);
  assert.ok(stripVTControlCharacters(pi.terminal()).includes('pending_context'));
  await closeInbox(pi);
  assert.equal(f.modelProvider.requests.length, 1);
  assert.equal(f.modelProvider.heldCount, 1);
  f.modelProvider.release(); await pi.event('agent_settled');
  await pi.submit('idle prompt after disconnected viewing');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 2, 'disconnected local prompt settled');
  assert.equal(f.modelProvider.requests.length, 2);
  assert.ok(JSON.stringify(f.modelProvider.requests[1].messages).includes(notice), 'read notice stayed pending for next idle prompt despite disconnect');
});

test('32 pending notices reject control before injection; processed unread history evicts oldest with warning', { timeout: 90000 }, async t => {
  const f = await setup(t); const pi = await f.launch(); const agent = await enableControl(f, pi);
  for (let index = 1; index <= 32; index++) {
    assert.equal((await f.send(agent.agentId, 'notice', `capacity notice ${String(index).padStart(2, '0')} marker`)).status, 202);
  }
  await waitFor(() => pi.terminal().includes('32 unread'), 'all 32 pending notices received');
  await freshTerminal(pi, () => pi.submit('/bus inbox'), 'unread notice');
  await freshTerminal(pi, () => pi.input('\r'), 'capacity notice 32 marker');
  await closeInbox(pi);
  await freshTerminal(pi, () => pi.submit('/bus'), 'unread=31');
  assert.equal(f.modelProvider.requests.length, 0, 'opening inbox starts no turn');
  await freshTerminal(pi, async () => {
    assert.equal((await f.send(agent.agentId, 'prompt', 'overflow control must never inject')).status, 202);
  }, 'discard/capacity warnings');
  await freshTerminal(pi, () => pi.submit('/bus'), 'pending-control=empty');
  assert.equal((await pi.events()).filter(e => e.type === 'input' && e.source === 'extension').length, 0);
  assert.equal(f.modelProvider.requests.length, 0);
  await pi.submit('consume all small pending notices'); await pi.event('agent_settled');
  assert.equal(f.modelProvider.requests.length, 1);
  const messages = JSON.stringify(f.modelProvider.requests[0].messages);
  for (let index = 1; index <= 32; index++) assert.ok(messages.includes(`capacity notice ${String(index).padStart(2, '0')} marker`));
  assert.ok(!messages.includes('overflow control must never inject'));
  await freshTerminal(pi, async () => {
    assert.equal((await f.send(agent.agentId, 'notice', 'replacement notice 33 marker')).status, 202);
  }, '1 discard/capacity warnings');
  await freshTerminal(pi, () => pi.submit('/bus'), 'unread=31');
  await freshTerminal(pi, () => pi.submit('/bus inbox'), 'Inbox (read only)');
  await freshTerminal(pi, () => pi.input('\r'), 'replacement notice 33 marker');
  await freshTerminal(pi, () => pi.input('\x1b'), 'Inbox (read only)');
  // Newest-first list: clamping at the bottom exposes the oldest retained record.
  // Custom UI receives terminal input chunks, not an abstract sequence of keys.
  for (let step = 0; step < 40; step++) { pi.input('\x1b[B'); await delay(30); }
  await delay(200);
  await freshTerminal(pi, () => pi.input('\r'), 'capacity notice 02 marker');
  assert.ok(stripVTControlCharacters(pi.terminal()).includes('context_inclusion_attempted'));
  await closeInbox(pi);
  assert.equal(f.modelProvider.requests.length, 1, 'history navigation neither starts a turn nor drains new mail');
  await pi.submit('consume replacement pending notice');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 2, 'replacement notice prompt settled');
  assert.ok(JSON.stringify(f.modelProvider.requests[1].messages).includes('replacement notice 33 marker'));
});

test('delayed real registration response cannot reopen old producers after reload', { timeout: 60000 }, async t => {
  const f = await setup(t); const proxy = await f.proxy();
  proxy.gates.push(r => r.method === 'PUT');
  const pi = await f.launch({ env: { PI_AGENT_BUS_URL: proxy.url } });
  const registration = await waitFor(() => proxy.records.find(r => r.method === 'PUT' && r.hold && r.ended), 'upstream registration completed with response held');
  assert.equal(registration.status, 204);
  const oldId = JSON.parse(registration.body).agentId;
  await pi.submit('/reload'); await pi.event('session_start', e => e.reason === 'reload');
  await waitFor(() => stripVTControlCharacters(pi.terminal()).includes('Reloaded keybindings'), 'replacement editor restored');
  const replacement = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.agentId !== oldId && a.receiving), 'replacement receiving independently of old registration');
  await waitFor(() => registration.closed, 'Bun abort closes held registration response');
  const before = proxy.records.length;
  registration.release();
  t.diagnostic(`registration release boundary: ${registration.releaseBoundary}; upstream PUT already completed, no tombstone/rollback asserted`);
  assert.equal(registration.releaseBoundary, 'downstream-already-closed');
  await delay(5500); // Cross a normal heartbeat interval, not only immediate callbacks.
  const late = proxy.records.slice(before);
  assert.ok(!late.some(r => r.path.includes(oldId) && r.method !== 'DELETE'), 'no old registration heartbeat, SSE open or retry producer');
  assert.ok(!proxy.records.some(r => r.method === 'POST'), 'no outbound message produced by stale completion');
  assert.equal(f.modelProvider.requests.length, 0);
  assert.equal((await f.send(replacement.agentId, 'notice', 'replacement remains usable after delayed registration')).status, 202);
  await waitFor(() => pi.terminal().includes('1 unread'), 'replacement receives fresh notice');
  await pi.submit('use replacement registration'); await pi.event('agent_settled');
  assert.ok(JSON.stringify(f.modelProvider.requests[0].messages).includes('replacement remains usable after delayed registration'));
  assert.deepEqual(proxy.errors, []);
});

test('held discovery and old SSE are aborted across reload and shutdown without stale UI or injection', { timeout: 90000 }, async t => {
  const f = await setup(t); const proxy = await f.proxy();
  const pi = await f.launch({ env: { PI_AGENT_BUS_URL: proxy.url } });
  const agent = await enableControl(f, pi);
  const oldStream = await waitFor(() => proxy.records.find(r => r.path.includes(`/v1/events?agentId=${agent.agentId}`) && r.status === 200), 'old SSE established');
  oldStream.hold = true;
  const stale = 'held old SSE control must not reach replacement';
  assert.equal((await f.send(agent.agentId, 'prompt', stale)).status, 202);
  await waitFor(() => Buffer.concat(oldStream.chunks).toString().includes(stale), 'real upstream SSE control bytes held');
  proxy.gates.push(r => r.method === 'GET' && r.path.startsWith('/v1/agents'));
  await pi.submit('/agents');
  const discovery = await waitFor(() => proxy.records.find(r => r.method === 'GET' && r.path.startsWith('/v1/agents') && r.hold && r.ended), 'real discovery response held');
  assert.equal(discovery.status, 200);
  await pi.submit('/reload'); await pi.event('session_start', e => e.reason === 'reload');
  await waitFor(() => stripVTControlCharacters(pi.terminal()).includes('Reloaded keybindings'), 'reload editor ready despite old discovery');
  const replacement = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.agentId !== agent.agentId && a.receiving), 'new runtime receiving');
  await waitFor(() => oldStream.closed && discovery.closed, 'Bun abort closes old discovery and SSE');
  const output = pi.terminalOffset(); const requests = proxy.records.length;
  discovery.release(); oldStream.release();
  t.diagnostic(`reload release boundaries: discovery=${discovery.releaseBoundary}, SSE=${oldStream.releaseBoundary}; native abort prevents downstream callback delivery`);
  assert.equal(discovery.releaseBoundary, 'downstream-already-closed');
  assert.equal(oldStream.releaseBoundary, 'downstream-already-closed');
  await delay(5500);
  assert.ok(!proxy.records.slice(requests).some(r => r.path.includes(agent.agentId) && r.method !== 'DELETE'));
  assert.ok(!(await pi.events()).some(e => e.type === 'input' && e.source === 'extension'));
  assert.equal(f.modelProvider.requests.length, 0);
  assert.doesNotMatch(stripVTControlCharacters(pi.terminalSince(output)), /Read only|held old SSE control/);
  await freshTerminal(pi, () => pi.submit('/bus'), 'unread=0');
  assert.equal((await f.send(replacement.agentId, 'notice', 'fresh replacement SSE usable')).status, 202);
  await waitFor(() => pi.terminal().includes('1 unread'), 'new runtime mail arrives');
  await pi.submit('replacement after stale discovery'); await pi.event('agent_settled');
  assert.ok(JSON.stringify(f.modelProvider.requests[0].messages).includes('fresh replacement SSE usable'));
  assert.ok(!JSON.stringify(f.modelProvider.requests[0].messages).includes(stale));
  const newStream = await waitFor(() => proxy.records.find(r => r.path.includes(`/v1/events?agentId=${replacement.agentId}`) && r.status === 200), 'replacement SSE established');
  newStream.hold = true;
  assert.equal((await f.send(replacement.agentId, 'notice', 'held shutdown SSE marker')).status, 202);
  await waitFor(() => Buffer.concat(newStream.chunks).toString().includes('held shutdown SSE marker'), 'shutdown SSE bytes held');
  await pi.quit();
  await waitFor(() => newStream.closed, 'shutdown closes native SSE connection');
  const stopped = proxy.records.length;
  newStream.release();
  assert.equal(newStream.releaseBoundary, 'downstream-already-closed');
  await delay(5500);
  assert.equal(proxy.records.length, stopped, 'no producers reopen after process shutdown');
  assert.ok(!proxy.records.some(r => r.method === 'POST'));
  assert.equal(f.modelProvider.requests.length, 1);
  assert.deepEqual(proxy.errors, []);
});

const noticeBatches = events => events.filter(e => e.type === 'message_start' && e.message.customType === 'agent-bus-mail').map(e => e.message);

test('idle notice hooks select whole FIFO batches by 16KiB original UTF-8 body bytes', { timeout: 60000 }, async t => {
  const f = await setup(t); const pi = await f.launch(); const agent = await f.receiving(pi.cwd);
  const first = 'é'.repeat(4096);
  const second = '界'.repeat(2730) + 'xy';
  const third = 'remainder after exact original-body budget';
  assert.equal(Buffer.byteLength(first), 8192); assert.equal(Buffer.byteLength(second), 8192);
  for (const body of [first, second, third]) assert.equal((await f.send(agent.agentId, 'notice', body)).status, 202);
  await waitFor(() => pi.terminal().includes('3 unread'), 'all batch notices received');
  assert.equal(f.modelProvider.requests.length, 0);
  await pi.submit('first idle batch prompt'); await pi.event('agent_settled');
  let batches = noticeBatches(await pi.events());
  assert.equal(batches.length, 1);
  assert.equal(batches[0].details.records.length, 2, 'framing overhead does not reduce the original-body budget');
  assert.ok(batches[0].content.includes(first)); assert.ok(batches[0].content.includes(second));
  assert.ok(batches[0].content.indexOf(first) < batches[0].content.indexOf(second), 'whole bodies remain FIFO');
  assert.ok(Buffer.byteLength(batches[0].content) > 16384, 'encoded framing is additional to the 16KiB original bodies');
  assert.ok(!batches[0].content.includes(third));
  assert.ok(!JSON.stringify(f.modelProvider.requests[0].messages).includes(third));
  await pi.submit('second idle batch prompt');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 2, 'remainder idle prompt settled');
  batches = noticeBatches(await pi.events());
  assert.equal(batches.length, 2);
  assert.equal(batches[1].details.records.length, 1);
  assert.ok(batches[1].content.includes(third));
  assert.ok(!batches[1].content.includes(first)); assert.ok(!batches[1].content.includes(second));
  assert.ok(JSON.stringify(f.modelProvider.requests[1].messages).includes(third));
});

test('notice arriving during an actual provider retry stays pending until a later idle prompt', { timeout: 60000 }, async t => {
  const f = await setup(t);
  const pi = await f.launch({ settings: { retry: { enabled: true, maxRetries: 2, baseDelayMs: 50,
    provider: { maxRetries: 0, timeoutMs: 10000 } } } });
  const agent = await f.receiving(pi.cwd);
  f.modelProvider.scripts.push({ error: 'synthetic overloaded provider' },
    { hold: true, error: 'synthetic overloaded provider retry' }, { hold: true });
  await pi.submit('local prompt requiring real automatic retry');
  await pi.event('message_end', e => e.message.role === 'assistant' && e.message.stopReason === 'error');
  await waitFor(() => f.modelProvider.requests.length === 2 && f.modelProvider.heldCount === 1, 'actual retry request held');
  assert.equal((await pi.events()).filter(e => e.type === 'agent_settled').length, 0);
  const notice = 'pending notice arriving during retry request';
  assert.equal((await f.send(agent.agentId, 'notice', notice)).status, 202);
  await waitFor(() => pi.terminal().includes('1 unread'), 'retry-time notice received');
  f.modelProvider.release();
  await waitFor(() => f.modelProvider.requests.length === 3 && f.modelProvider.heldCount === 1, 'next actual retry begins after notice arrival');
  assert.equal(noticeBatches(await pi.events()).length, 0, 'retry continuation cannot drain notices');
  assert.ok(!JSON.stringify(f.modelProvider.requests).includes(notice));
  f.modelProvider.release(); await pi.event('agent_settled');
  assert.equal(f.modelProvider.requests.length, 3);
  await pi.submit('later idle prompt after retry');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 2, 'post-retry idle prompt settled');
  assert.equal(f.modelProvider.requests.length, 4);
  assert.ok(JSON.stringify(f.modelProvider.requests[3].messages).includes(notice));
  assert.equal(noticeBatches(await pi.events()).length, 1);
});

test('successful automatic compaction recovery does not drain notices arriving during summarization', { timeout: 60000 }, async t => {
  const f = await setup(t);
  const pi = await f.launch({ settings: { compaction: { enabled: true, keepRecentTokens: 64 } } });
  for (let turn = 1; turn <= 3; turn++) {
    await pi.submit(`recovery history ${turn}: ${'bounded synthetic history '.repeat(40)}`);
    await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === turn, 'recovery history settled');
  }
  const agent = await f.receiving(pi.cwd);
  f.modelProvider.scripts.push({ error: 'maximum context length is 128000 tokens' },
    { hold: true, text: 'Synthetic compacted history summary.' }, { hold: true, text: 'Synthetic recovered response.' });
  await pi.submit('trigger successful overflow recovery');
  const preparation = await pi.event('session_before_compact', e => e.reason === 'overflow');
  assert.equal(preparation.willRetry, true); assert.ok(preparation.messagesToSummarize > 0);
  await waitFor(() => f.modelProvider.requests.length === 5 && f.modelProvider.heldCount === 1, 'real summarization request held');
  const notice = 'new notice during successful automatic compaction';
  assert.equal((await f.send(agent.agentId, 'notice', notice)).status, 202);
  await waitFor(() => pi.terminal().includes('1 unread'), 'notice received during compaction');
  f.modelProvider.release();
  const compacted = await pi.event('session_compact', e => e.reason === 'overflow');
  assert.equal(compacted.willRetry, true); assert.equal(compacted.fromExtension, false);
  assert.match(compacted.compactionEntry.summary, /Synthetic compacted history summary/);
  await waitFor(() => f.modelProvider.requests.length === 6 && f.modelProvider.heldCount === 1, 'actual post-compaction recovery request held');
  assert.equal((await pi.events()).filter(e => e.type === 'agent_settled').length, 3);
  assert.equal(noticeBatches(await pi.events()).length, 0);
  assert.ok(!JSON.stringify(f.modelProvider.requests[5].messages).includes(notice));
  f.modelProvider.release();
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 4, 'successful recovery fully settled');
  assert.equal(noticeBatches(await pi.events()).length, 0);
  await pi.submit('later idle prompt after successful recovery');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 5, 'post-recovery idle prompt settled');
  assert.equal(f.modelProvider.requests.length, 7);
  assert.ok(JSON.stringify(f.modelProvider.requests[6].messages).includes(notice));
  assert.equal(noticeBatches(await pi.events()).length, 1);
  assert.ok(!(await pi.events()).some(e => e.type === 'session_compact_failed'));
});

test('new, reload, resume, fork, tree and model lifecycle uses actual Pi events', { timeout: 90000 }, async t => {
  const f = await setup(t); const pi = await f.launch(); let agent = await f.receiving(pi.cwd);
  await pi.submit('saved fixture conversation'); await pi.event('agent_settled');
  const saved = pi.started.sessionFile;
  await pi.submit('/label fixture-label');
  await waitFor(async () => (await f.receiving(pi.cwd)).label === 'fixture-label', 'explicit label');
  await pi.submit('/fixture-model qwen-fixture'); await pi.event('model_select', e => e.model.id === 'qwen-fixture');
  await waitFor(async () => (await f.receiving(pi.cwd)).model.id === 'qwen-fixture', 'ordinary Pi Qwen model participates');
  assert.equal((await f.receiving(pi.cwd)).agentId, agent.agentId);
  await pi.submit('/reload'); await pi.event('session_start', e => e.reason === 'reload');
  await waitFor(() => pi.terminal().includes('Reloaded keybindings'), 'reload restores input handling');
  agent = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.receiving && a.agentId !== agent.agentId), 'reload replacement');
  assert.equal(agent.label, 'fixture-label'); assert.equal(agent.acceptsControl, false);
  await pi.submit('/new'); await pi.event('session_start', e => e.reason === 'new');
  agent = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.receiving && a.agentId !== agent.agentId), 'new replacement');
  assert.notEqual(agent.label, 'fixture-label');
  await pi.submit(`/fixture-resume ${saved}`); await pi.event('session_start', e => e.reason === 'resume');
  agent = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.receiving && a.agentId !== agent.agentId), 'resume replacement');
  assert.equal(agent.label, 'fixture-label');
  const entries = (await readFile(saved, 'utf8')).trim().split('\n').map(JSON.parse);
  const first = entries.find(e => e.type === 'message' && e.message.role === 'user');
  await pi.submit(`/fixture-tree ${first.id}`); await pi.event('session_tree');
  assert.equal((await f.receiving(pi.cwd)).agentId, agent.agentId);
  await waitFor(async () => (await f.receiving(pi.cwd)).label !== 'fixture-label', 'active-branch label restore');
  pi.input('\x03'); await delay(100); // Tree selection restores the selected prompt into the editor.
  await pi.submit(`/fixture-fork ${first.id}`); await pi.event('session_start', e => e.reason === 'fork');
  const forked = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.receiving && a.agentId !== agent.agentId), 'fork replacement');
  assert.notEqual(forked.sessionId, agent.sessionId);
});

async function enableControl(f, pi) {
  await f.receiving(pi.cwd);
  const promptsBefore = (await pi.events()).filter(e => e.type === 'ui_prompt_start').length;
  await pi.submit('/bus control on');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'ui_prompt_start').length > promptsBefore, 'fresh local consent prompt');
  await delay(100); pi.input('\r');
  return waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.receiving && a.acceptsControl), 'local consent advertised');
}

for (const interception of ['handled', 'transform', 'delay']) {
  test(`${interception} remote input retains exact control slot until consumption or reload`, { timeout: 60000 }, async t => {
    const f = await setup(t); const pi = await f.launch(); const agent = await enableControl(f, pi);
    await pi.control({ input: interception });
    assert.equal((await f.send(agent.agentId, 'prompt', 'first controlled marker')).status, 202);
    await pi.event('input', e => e.source === 'extension' && e.text.includes('first controlled marker'));
    if (interception === 'transform') await pi.event('agent_settled');
    if (interception === 'delay') {
      // A local submission can settle while the remote input hook is still pending.
      await pi.submit('unrelated local input'); await pi.event('agent_settled');
    }
    assert.equal((await f.send(agent.agentId, 'prompt', 'must not enter second slot')).status, 202);
    await delay(500);
    assert.ok(!(await pi.events()).some(e => e.type === 'input' && e.text.includes('must not enter second slot')));
    await pi.submit('/bus');
    await waitFor(() => pi.terminal().includes('pending-control=occupied'), 'visible unmatched slot and recovery');
    if (interception === 'delay') {
      await pi.releaseInput(); await pi.event('message_start', e => e.message.role === 'user' && JSON.stringify(e.message.content).includes('first controlled marker'));
      assert.equal((await f.send(agent.agentId, 'prompt', 'after matching consumption')).status, 202);
      await pi.event('input', e => e.source === 'extension' && e.text.includes('after matching consumption'));
    } else {
      await pi.submit('/reload'); await pi.event('session_start', e => e.reason === 'reload');
      const replacement = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.receiving && a.agentId !== agent.agentId), 'reload clears stuck slot');
      assert.equal(replacement.acceptsControl, false);
    }
  });
}

test('control text cannot expand commands, and queued follow-ups do not drain notices', { timeout: 60000 }, async t => {
  const f = await setup(t); const pi = await f.launch(); const agent = await enableControl(f, pi);
  assert.equal((await f.send(agent.agentId, 'prompt', '/bus control off')).status, 202);
  await pi.event('agent_settled');
  assert.ok(JSON.stringify(f.modelProvider.requests[0].messages).includes('/bus control off'));
  assert.equal((await f.receiving(pi.cwd)).acceptsControl, true, 'bus text is not dispatched as a slash command');
  f.modelProvider.scripts.push({ hold: true });
  await pi.submit('held local turn');
  await waitFor(() => f.modelProvider.requests.length === 2, 'held provider request');
  assert.equal((await f.send(agent.agentId, 'notice', 'notice only for next idle prompt')).status, 202);
  assert.equal((await f.send(agent.agentId, 'prompt', 'queued remote follow-up')).status, 202);
  await pi.event('input', e => e.source === 'extension' && e.text.includes('queued remote follow-up'));
  f.modelProvider.release();
  await waitFor(() => f.modelProvider.requests.length === 3, 'follow-up provider request');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length >= 2, 'follow-up settled');
  assert.ok(!JSON.stringify(f.modelProvider.requests[2].messages).includes('notice only for next idle prompt'));
  await pi.submit('next idle local prompt');
  await waitFor(() => f.modelProvider.requests.length === 4, 'next idle provider request');
  assert.ok(JSON.stringify(f.modelProvider.requests[3].messages).includes('notice only for next idle prompt'));
});

test('rejected small-session compaction does not free an unmatched remote control slot', { timeout: 60000 }, async t => {
  const f = await setup(t);
  const pi = await f.launch();
  await pi.submit('small synthetic context'); await pi.event('agent_settled');
  await pi.submit('second synthetic conversation turn');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 2, 'second turn settled');
  const agent = await enableControl(f, pi);
  await pi.control({ input: 'handled' });
  assert.equal((await f.send(agent.agentId, 'prompt', 'unmatched before compaction')).status, 202);
  await pi.event('input', e => e.source === 'extension' && e.text.includes('unmatched before compaction'));
  await pi.submit('/compact');
  const failure = await pi.event('session_compact_failed', e => e.reason === 'manual');
  assert.equal(failure.aborted, false);
  assert.match(failure.errorMessage, /Nothing to compact/);
  await pi.submit('/bus');
  await waitFor(() => pi.terminal().includes('pending-control=occupied'), 'compaction failure preserves unmatched slot');
  assert.equal((await f.send(agent.agentId, 'prompt', 'not admitted after compaction failure')).status, 202);
  await delay(400);
  assert.ok(!(await pi.events()).some(e => e.type === 'input' && e.text.includes('not admitted after compaction failure')));
});

for (const outcome of ['failure', 'cancellation']) {
test(`in-progress manual compaction rejects control preflight and retains its slot through ${outcome} and settlement until reload`, { timeout: 60000 }, async t => {
  const f = await setup(t);
  const pi = await f.launch({ settings: { compaction: { enabled: false, keepRecentTokens: 64 } } });
  for (let turn = 1; turn <= 3; turn++) {
    await pi.submit(`synthetic history ${turn}: ${'bounded compaction history '.repeat(40)}`);
    await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === turn, 'history turn settled');
  }
  const agent = await enableControl(f, pi);
  f.modelProvider.scripts.push({ hold: true, error: 'synthetic held compaction failure' });
  await pi.submit('/compact');
  const preparation = await pi.event('session_before_compact', e => e.reason === 'manual');
  assert.equal(preparation.keepRecentTokens, 64);
  assert.ok(preparation.messagesToSummarize > 0);
  await waitFor(() => f.modelProvider.heldCount === 1 && f.modelProvider.requests.length === 4, 'actual compaction provider request held');
  assert.ok(!(await pi.events()).some(e => e.type === 'session_compact_failed'));
  assert.equal((await f.send(agent.agentId, 'prompt', 'rejected during active compaction')).status, 202);
  await waitFor(() => stripVTControlCharacters(pi.terminal()).includes('Cannot submit a prompt while compaction is in progress'), 'actual SDK preflight rejection');
  assert.equal(f.modelProvider.heldCount, 1, 'provider remains held through rejection');
  const occupied = async () => {
    const before = pi.terminal().length;
    await pi.submit('/bus');
    await waitFor(() => pi.terminal().slice(before).includes('pending-control=occupied'), 'fresh occupied-slot status');
  };
  await occupied();
  assert.equal((await f.send(agent.agentId, 'prompt', 'second during compaction')).status, 202);
  await delay(400);
  if (outcome === 'cancellation') pi.input('\x1b');
  else f.modelProvider.release();
  const failure = await pi.event('session_compact_failed', e => e.reason === 'manual');
  assert.equal(failure.aborted, outcome === 'cancellation');
  assert.equal(failure.willRetry, false);
  if (outcome === 'cancellation') {
    assert.equal(failure.errorMessage, undefined);
    // Cancellation must finish without the provider ever sending its held error.
    assert.equal(f.modelProvider.heldCount, 1);
    f.modelProvider.release();
  } else assert.match(failure.errorMessage, /synthetic held compaction failure/);
  await occupied();
  await pi.submit('unrelated local settlement after compaction failure');
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 4, 'local run fully settled');
  await occupied();
  assert.equal((await f.send(agent.agentId, 'prompt', 'second after settlement')).status, 202);
  await delay(400);
  const events = await pi.events();
  assert.equal(events.filter(e => e.type === 'input' && e.source === 'extension').length, 0, 'preflight-rejected and subsequent controls never enter input hooks');
  assert.ok(!JSON.stringify(f.modelProvider.requests).includes('second after settlement'));
  assert.ok(!JSON.stringify(events.filter(e => e.type === 'message_start')).includes('rejected during active compaction'));
  await pi.submit('/reload'); await pi.event('session_start', e => e.reason === 'reload');
  const replacement = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.receiving && a.agentId !== agent.agentId), 'reload replacement');
  assert.equal(replacement.acceptsControl, false);
  // session_start and registration precede dismissal of Pi's non-input reload box.
  await waitFor(() => stripVTControlCharacters(pi.terminal()).includes('Reloaded keybindings'), 'reload restores the interactive editor');
  await enableControl(f, pi);
  assert.equal((await f.send(replacement.agentId, 'prompt', 'control admitted only after reload')).status, 202);
  await pi.event('message_start', e => e.message.role === 'user' && JSON.stringify(e.message.content).includes('control admitted only after reload'));
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 5, 'post-reload control settled');
});

}

test('automatic overflow compaction failure preserves a pending control slot through settlement', { timeout: 60000 }, async t => {
  const f = await setup(t);
  const pi = await f.launch({ settings: { compaction: { enabled: true, keepRecentTokens: 64 } } });
  for (let turn = 1; turn <= 3; turn++) {
    await pi.submit(`automatic compaction history ${turn}: ${'bounded synthetic history '.repeat(40)}`);
    await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === turn, 'automatic fixture history settled');
  }
  const agent = await enableControl(f, pi);
  await pi.control({ input: 'handled' });
  assert.equal((await f.send(agent.agentId, 'prompt', 'pending before automatic compaction')).status, 202);
  await pi.event('input', e => e.source === 'extension' && e.text.includes('pending before automatic compaction'));
  await pi.control({});
  f.modelProvider.scripts.push(
    { error: 'maximum context length is 128000 tokens' },
    { hold: true, error: 'synthetic automatic compaction failure' },
  );
  await pi.submit('trigger synthetic context overflow');
  const preparation = await pi.event('session_before_compact', e => e.reason === 'overflow');
  assert.equal(preparation.willRetry, true, 'actual overflow recovery, not manual or threshold compaction');
  assert.ok(preparation.messagesToSummarize > 0);
  await waitFor(() => f.modelProvider.heldCount === 1 && f.modelProvider.requests.length === 5, 'automatic summarization request held');
  assert.equal((await pi.events()).filter(e => e.type === 'agent_settled').length, 3, 'overflow recovery has not settled while summarization is held');
  const occupied = async () => {
    const before = pi.terminal().length;
    await pi.submit('/bus');
    await waitFor(() => pi.terminal().slice(before).includes('pending-control=occupied'), 'fresh automatic-compaction occupied-slot status');
  };
  await occupied();
  assert.equal((await f.send(agent.agentId, 'prompt', 'blocked during automatic compaction')).status, 202);
  await delay(400);
  f.modelProvider.release();
  const failure = await pi.event('session_compact_failed', e => e.reason === 'overflow');
  assert.equal(failure.aborted, false);
  assert.equal(failure.willRetry, false, 'failed summarization prevents overflow continuation');
  assert.match(failure.errorMessage, /Context overflow recovery failed:.*synthetic automatic compaction failure/);
  await waitFor(async () => (await pi.events()).filter(e => e.type === 'agent_settled').length === 4, 'failed automatic recovery fully settled');
  await occupied();
  assert.equal((await f.send(agent.agentId, 'prompt', 'blocked after automatic settlement')).status, 202);
  await delay(400);
  assert.equal(f.modelProvider.requests.length, 5, 'no automatic retry or blocked control provider request');
  const inputs = (await pi.events()).filter(e => e.type === 'input' && e.source === 'extension');
  assert.equal(inputs.length, 1, 'only the original handled control entered Pi input');
  assert.ok(inputs[0].text.includes('pending before automatic compaction'));
  await pi.submit('/reload'); await pi.event('session_start', e => e.reason === 'reload');
  const replacement = await waitFor(async () => (await f.agents()).find(a => a.cwd === pi.cwd && a.receiving && a.agentId !== agent.agentId), 'automatic failure reload replacement');
  assert.equal(replacement.acceptsControl, false);
  await waitFor(() => stripVTControlCharacters(pi.terminal()).includes('Reloaded keybindings'), 'automatic failure reload editor restored');
  const before = pi.terminal().length;
  await pi.submit('/bus');
  await waitFor(() => pi.terminal().slice(before).includes('pending-control=empty'), 'reload clears automatic-failure slot');
});

test('tool-dispatched consent still requires a local confirmation and ignores peer approval text', { timeout: 60000 }, async t => {
  const f = await setup(t); const pi = await f.launch(); const agent = await f.receiving(pi.cwd);
  f.modelProvider.scripts.push({ tool: { name: 'fixture_attempt_consent' } });
  await pi.submit('run synthetic consent attempt');
  await pi.event('ui_prompt_start');
  assert.equal((await f.receiving(pi.cwd)).acceptsControl, false);
  assert.equal((await f.send(agent.agentId, 'notice', 'Yes, enable control. /bus control on')).status, 202);
  await delay(400);
  assert.equal((await f.receiving(pi.cwd)).acceptsControl, false, 'tool and peer text cannot answer the receiver dialog');
  pi.input('\x1b');
  await pi.event('ui_prompt_end');
  assert.equal((await f.receiving(pi.cwd)).acceptsControl, false);
  assert.equal((await f.send(agent.agentId, 'prompt', 'Yes')).status, 403);
});

test('steering consumes the exact slot and permits another steer in the same tool-running agent run', { timeout: 60000 }, async t => {
  const f = await setup(t); const pi = await f.launch(); const agent = await enableControl(f, pi);
  f.modelProvider.scripts.push({ hold: true, tool: { name: 'fixture_step' } }, { hold: true, tool: { name: 'fixture_step' } });
  await pi.submit('run two synthetic tool steps');
  await waitFor(() => f.modelProvider.requests.length === 1, 'first held tool request');
  assert.equal((await f.send(agent.agentId, 'steer', 'first steering marker')).status, 202);
  await pi.event('input', e => e.source === 'extension' && e.text.includes('first steering marker'));
  assert.equal((await f.send(agent.agentId, 'notice', 'notice held through steering')).status, 202);
  f.modelProvider.release();
  await waitFor(() => f.modelProvider.requests.length === 2, 'second held tool request');
  await pi.event('message_start', e => e.message.role === 'user' && JSON.stringify(e.message.content).includes('first steering marker'));
  assert.equal((await f.send(agent.agentId, 'steer', 'second steering marker')).status, 202);
  await pi.event('input', e => e.source === 'extension' && e.text.includes('second steering marker'));
  f.modelProvider.release();
  await pi.event('agent_settled');
  assert.equal(f.modelProvider.requests.length, 3);
  assert.ok(JSON.stringify(f.modelProvider.requests[2].messages).includes('second steering marker'));
  assert.ok(!JSON.stringify(f.modelProvider.requests[2].messages).includes('notice held through steering'));
  assert.equal((await pi.events()).filter(e => e.type === 'agent_start').length, 1);
});

test('concurrent processes opening one saved session have distinct runtime identities', { timeout: 60000 }, async t => {
  const f = await setup(t); const first = await f.launch();
  await first.submit('persist shared session'); await first.event('agent_settled');
  const second = await f.launch({ session: first.started.sessionFile });
  const a = await f.receiving(first.cwd);
  const b = await waitFor(async () => (await f.agents()).find(item => item.agentId !== a.agentId && item.sessionId === a.sessionId), 'second concurrent runtime on saved session');
  assert.notEqual(a.agentId, b.agentId); assert.notEqual(a.pid, b.pid);
  await second.quit();
  await waitFor(async () => !(await f.agents()).some(item => item.agentId === b.agentId), 'only stopped runtime removed');
  assert.ok((await f.agents()).some(item => item.agentId === a.agentId && item.receiving));
});

for (const [name, args] of [
  ['Qwen-style discovery suppression with CLI offline', ['--offline', '--no-extensions']],
  ['discovery suppression without offline', ['--no-extensions']],
  ['explicit Switchboard with CLI offline', ['--offline', '--no-extensions', '-e', join(extensionPackage, 'index.ts')]],
]) {
  test(`Pinned Bun exclusion CLI, synthetic composition: ${name}`, { timeout: 45000 }, async t => {
    const f = await setup(t);
    let attempts = 0;
    const sink = createHttpServer((_req, res) => {
      attempts++;
      res.writeHead(503); res.end();
    });
    await new Promise(resolve => sink.listen(0, '127.0.0.1', resolve));
    t.after(async () => {
      sink.closeAllConnections();
      await new Promise(resolve => sink.close(resolve));
    });
    const pi = await f.launch({ args: [...args, '-e', join(fixtures, 'observer.js')],
      env: { PI_AGENT_BUS_URL: `http://127.0.0.1:${sink.address().port}` } });
    assert.equal(pi.started.mode, 'tui');
    await pi.submit('/fixture-alive'); await pi.event('fixture_alive');
    await delay(5500);
    await pi.submit('/fixture-alive');
    await waitFor(async () => (await pi.events()).filter(e => e.type === 'fixture_alive').length === 2, 'excluded TUI remains responsive after observation window');
    assert.equal(attempts, 0, 'zero bus HTTP request attempts, not merely an empty final registry');
    assert.ok(!(await pi.events()).some(e => e.type === 'discovery_sentinel'), 'discovery sentinel stays unloaded');
    assert.doesNotMatch(stripVTControlCharacters(pi.terminal()), /failed to load|error loading|extension error|reload failed/i);
    await pi.quit();
    assert.equal(attempts, 0, 'shutdown makes no bus request either');
  });
}

for (const [name, options] of [
  ['disabled', { env: { PI_AGENT_BUS_ENABLED: '0' } }],
  ['offline', { env: { PI_OFFLINE: '1' } }],
  ['RPC', { args: ['--mode', 'rpc'] }],
  ['print', { args: ['--print', 'negative mode prompt'] }],
]) {
  test(`${name} session does not register`, { timeout: 45000 }, async t => {
    const f = await setup(t); const pi = await f.launch(options);
    await delay(1500);
    assert.ok(!(await f.agents()).some(a => a.cwd === pi.cwd));
    assert.ok((await pi.events()).some(e => e.type === 'session_start'), 'extension observer really loaded');
  });
}
