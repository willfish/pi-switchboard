import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, writeFile, rm, readdir, readFile, readlink } from 'node:fs/promises';
import { createServer, createConnection } from 'node:net';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';

// Explicit artifact input prevents accidentally testing a source-tree server.
const executable = process.env.PI_AGENT_BUS_TEST_EXECUTABLE;
assert.ok(executable?.startsWith('/nix/store/'), 'supply a compiled Nix hub executable');

async function freePort() {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const port = server.address().port;
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  return port;
}

async function epmdPids() {
  if (process.platform !== 'linux') return new Set();
  const found = new Set();
  for (const pid of (await readdir('/proc')).filter(name => /^\d+$/.test(name))) {
    try {
      if ((await readFile(`/proc/${pid}/comm`, 'utf8')).trim() === 'epmd') found.add(pid);
    } catch (error) {
      if (!['ENOENT', 'ESRCH', 'EACCES'].includes(error.code)) throw error;
    }
  }
  return found;
}

// A test-only init hook observes and faults the running packaged VM through
// this fixture's private temporary directory. No distributed node, remote
// shell, or production diagnostic endpoint is enabled.
const runtimeProbe = `spawn(fun Wait() ->
  D = os:getenv("PI_AGENT_BUS_TEST_PROBE_DIR"),
  case file:read_file(filename:join(D, "probe.request")) of
    {ok, _} ->
      file:delete(filename:join(D, "probe.request")),
      file:write_file(filename:join(D, "probe.json"),
        json:encode(#{<<"node">> => atom_to_binary(node()), <<"alive">> => is_alive(),
          <<"crashDump">> => list_to_binary(os:getenv("ERL_CRASH_DUMP"))}));
    _ -> ok
  end,
  case file:read_file(filename:join(D, "fault.request")) of
    {ok, Kind} when Kind =:= <<"store">>; Kind =:= <<"listener">> ->
      file:delete(filename:join(D, "fault.request")),
      Current = fun(<<"store">>) -> whereis(bus_store);
        (<<"listener">>) ->
          [P] = [P || {Id,P,_,_} <- supervisor:which_children(bus_sup), Id =/= bus_store, is_pid(P)], P
      end,
      Old = Current(Kind),
      Mon = monitor(process, Old),
      exit(Old, kill),
      receive {'DOWN', Mon, process, Old, _} -> ok after 5000 -> error(fault_timeout) end,
      Deadline = erlang:monotonic_time(millisecond) + 5000,
      New = (fun Await() ->
        Candidate = try Current(Kind) catch _:_ -> undefined end,
        case is_pid(Candidate) andalso Candidate =/= Old of
          true -> Candidate;
          false ->
            true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 10 -> Await() end
        end
      end)(),
      file:write_file(filename:join(D, "fault.json"),
        json:encode(#{<<"kind">> => Kind, <<"changed">> => Old =/= New}));
    _ -> ok
  end,
  receive after 10 -> Wait() end
end).`;

async function start(t, tokenContents) {
  const directory = await mkdtemp(join(tmpdir(), 'switchboard-packaged-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const tokenFile = join(directory, 'token');
  if (tokenContents !== undefined) await writeFile(tokenFile, tokenContents, { mode: 0o600 });
  const port = await freePort();
  const epmdBefore = await epmdPids();
  const child = spawn(executable, ['-eval', runtimeProbe], {
    cwd: directory,
    env: {
      PATH: process.env.PATH,
      HOME: directory,
      TMPDIR: directory,
      PI_AGENT_BUS_TEST_PROBE_DIR: directory,
      PI_AGENT_BUS_BIND_HOST: '127.0.0.1',
      PI_AGENT_BUS_PORT: String(port),
      PI_AGENT_BUS_TOKEN_FILE: tokenFile,
      ERL_CRASH_DUMP: join(directory, 'forbidden.dump'),
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let diagnostics = '';
  child.stderr.on('data', chunk => {
    diagnostics = (diagnostics + chunk.toString('utf8')).slice(-65536);
  });
  // Register immediately, including the early startup-failure path.
  const exited = once(child, 'close');
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM');
      const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
      try { await exited; } finally { clearTimeout(timer); }
    }
  });
  return { child, exited, directory, port, epmdBefore, diagnostics: () => diagnostics, url: `http://127.0.0.1:${port}` };
}

async function checkRuntimeIsolation(runtime) {
  await writeFile(join(runtime.directory, 'probe.request'), 'inspect');
  const deadline = Date.now() + 2000;
  let probe;
  while (Date.now() < deadline && probe === undefined) {
    try {
      probe = JSON.parse(await readFile(join(runtime.directory, 'probe.json'), 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error;
      await delay(10);
    }
  }
  assert.deepEqual(probe, { node: 'nonode@nohost', alive: false, crashDump: '/dev/null' },
    'inspect actual running VM distribution state and forced crash-dump suppression');
  assert.deepEqual((await readdir(runtime.directory)).sort(), ['probe.json', 'token'],
    'isolated HOME/TMPDIR must contain only the fixture credential and explicit probe output');
  if (process.platform !== 'linux') return; // /proc evidence is Linux-specific.
  for (const pid of await epmdPids()) {
    assert.ok(runtime.epmdBefore.has(pid), 'packaged boot must not leave a newly started EPMD');
  }
  const root = `/proc/${runtime.child.pid}`;
  const args = (await readFile(`${root}/cmdline`, 'utf8')).split('\0');
  assert.ok(!args.some(arg => ['-name', '-sname', '-setcookie', '-remsh'].includes(arg)),
    'running VM must not use distribution arguments');
  assert.equal(args[args.indexOf('-start_epmd') + 1], 'false');
  const inodes = new Set();
  for (const fd of await readdir(`${root}/fd`)) {
    try {
      const target = await readlink(`${root}/fd/${fd}`);
      const match = /^socket:\[(\d+)\]$/.exec(target);
      if (match) inodes.add(match[1]);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error; // Descriptor closed during inspection.
    }
  }
  const listeners = [];
  for (const table of ['tcp', 'tcp6']) {
    const rows = (await readFile(`${root}/net/${table}`, 'utf8')).trim().split('\n').slice(1);
    for (const row of rows) {
      const fields = row.trim().split(/\s+/);
      if (fields[3] === '0A' && inodes.has(fields[9])) {
        const [address, port] = fields[1].split(':');
        listeners.push({ family: table, address, port: Number.parseInt(port, 16) });
      }
    }
  }
  assert.deepEqual(listeners, [{ family: 'tcp', address: '0100007F', port: runtime.port }],
    'VM must listen only on its configured IPv4 loopback HTTP address and port');
}

async function injectFault(runtime, kind) {
  await rm(join(runtime.directory, 'fault.json'), { force: true });
  await writeFile(join(runtime.directory, 'fault.request'), kind);
  const deadline = Date.now() + 6000;
  while (Date.now() < deadline) {
    try {
      const result = JSON.parse(await readFile(join(runtime.directory, 'fault.json'), 'utf8'));
      assert.deepEqual(result, { kind, changed: true }, 'packaged supervisor must replace the killed child');
      await ready(runtime);
      return;
    } catch (error) {
      if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error;
      await delay(10);
    }
  }
  assert.fail('packaged fault hook did not observe replacement');
}

const eventReaders = new WeakMap();
async function readEvent(reader, wanted, strict = false) {
  let state = eventReaders.get(reader);
  if (!state) {
    state = { buffered: '', decoder: new TextDecoder('utf-8', { fatal: true }) };
    eventReaders.set(reader, state);
  }
  while (true) {
    const end = state.buffered.indexOf('\n\n');
    if (end >= 0) {
      const frame = state.buffered.slice(0, end);
      state.buffered = state.buffered.slice(end + 2);
      assert.ok(Buffer.byteLength(frame) + 2 <= 1024 * 1024, 'fixture frame exceeded its byte bound');
      const lines = frame.split('\n');
      const type = lines.find(line => line.startsWith('event: '))?.slice(7);
      if (type === wanted) return JSON.parse(lines.filter(line => line.startsWith('data: '))
        .map(line => line.slice(6)).join('\n'));
      if (strict && (type !== undefined || lines.some(line => line.startsWith('data:')))) {
        assert.fail('unexpected event before the required presence frame');
      }
      continue;
    }
    assert.ok(Buffer.byteLength(state.buffered) <= 1024 * 1024, 'incomplete fixture frame exceeded its bound');
    const { done, value } = await reader.read();
    assert.equal(done, false, 'stream ended before the expected complete event');
    state.buffered += state.decoder.decode(value, { stream: true });
  }
}
const readNotice = reader => readEvent(reader, 'message');

const token = 'packaged-loopback-fixture-only';
const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
const sender = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const recipient = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const agent = agentId => ({
  agentId, sessionId: '11111111-1111-4111-8111-111111111111',
  host: 'fixture', cwd: '/fixture', sessionName: 'fixture', label: 'fixture',
  model: null, status: 'idle', pid: 1, acceptsControl: false,
});

async function ready(runtime) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    assert.equal(runtime.child.exitCode, null, 'hub exited during startup');
    try {
      const response = await fetch(`${runtime.url}/health`, { signal: AbortSignal.timeout(500) });
      assert.equal(response.status, 200);
      assert.deepEqual(await response.json(), { ok: true });
      return;
    } catch {
      await delay(25);
    }
  }
  assert.fail('packaged hub did not become healthy within ten seconds');
}

for (const [name, contents] of [['missing', undefined], ['empty', '']]) {
  test(`packaged hub refuses ${name} credential`, { timeout: 15000 }, async t => {
    const runtime = await start(t, contents);
    const [code, signal] = await runtime.exited;
    assert.equal(signal, null);
    assert.notEqual(code, 0);
    const reason = name === 'missing' ? 'missing_token_file' : 'empty_token';
    assert.ok(runtime.diagnostics().includes(`pi_agent_bus failed to start: ${reason}`),
      'hub must reject the credential specifically, not fail for an unrelated reason');
  });
}

test('packaged dashboard serves only fixed generic assets and preserves bearer-only discovery', { timeout: 20000 }, async t => {
  const runtime = await start(t, token);
  await ready(runtime);
  const marker = 'packaged-dashboard-private-presence';
  const put = await fetch(`${runtime.url}/v1/agents/${sender}`, {
    method: 'PUT', headers, body: JSON.stringify({ ...agent(sender), label: marker }),
    signal: AbortSignal.timeout(2000),
  });
  assert.equal(put.status, 204);
  for (const [path, type] of [
    ['/dashboard/', 'text/html'],
    ['/dashboard/dashboard.css', 'text/css'],
    ['/dashboard/dashboard.js', 'text/javascript'],
    ['/dashboard/protocol.js', 'text/javascript'],
  ]) {
    const response = await fetch(runtime.url + path, { signal: AbortSignal.timeout(2000) });
    assert.equal(response.status, 200, path);
    assert.ok(response.headers.get('content-type')?.startsWith(type));
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
    assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(response.headers.get('x-frame-options'), 'DENY');
    assert.ok(response.headers.get('content-security-policy')?.includes("frame-ancestors 'none'"));
    assert.equal(response.headers.get('access-control-allow-origin'), null);
    const body = await response.text();
    assert.ok(body.length > 0);
    assert.ok(!body.includes(marker), 'private presence leaked into an asset');
    assert.ok(!body.includes(token), 'credential leaked into an asset');
  }
  const head = await fetch(`${runtime.url}/dashboard/`, { method: 'HEAD', signal: AbortSignal.timeout(2000) });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
  const redirect = await fetch(runtime.url + '/', { redirect: 'manual', signal: AbortSignal.timeout(2000) });
  assert.equal(redirect.status, 302);
  assert.equal(redirect.headers.get('location'), '/dashboard/');
  // Fetch may normalize forbidden Host overrides; send this authority explicitly.
  const foreignHost = await new Promise((resolve, reject) => {
    const request = httpRequest(`${runtime.url}/dashboard/`, {
      headers: { host: `attacker.invalid:${runtime.port}` }, signal: AbortSignal.timeout(2000),
    }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { body += chunk; });
      response.once('error', reject);
      response.once('end', () => resolve({ status: response.statusCode, body }));
    });
    request.once('error', reject);
    request.end();
  });
  assert.equal(foreignHost.status, 403);
  assert.equal(foreignHost.body, 'Forbidden');
  const foreignOrigin = await fetch(`${runtime.url}/v1/agents`, {
    headers: { ...headers, origin: 'http://attacker.invalid' }, signal: AbortSignal.timeout(2000),
  });
  assert.equal(foreignOrigin.status, 403);
  const cookie = await fetch(`${runtime.url}/v1/agents`, {
    headers: { cookie: `token=${token}` }, signal: AbortSignal.timeout(2000),
  });
  assert.equal(cookie.status, 401);
  const native = await fetch(`${runtime.url}/v1/agents`, { headers, signal: AbortSignal.timeout(2000) });
  assert.equal(native.status, 200);
  assert.equal((await native.json()).agents.find(value => value.agentId === sender).receiving, false);
});

test('packaged hub registers, discovers and streams a notice, then stops', { timeout: 20000 }, async t => {
  const runtime = await start(t, token);
  await ready(runtime);
  const unauthenticated = await fetch(`${runtime.url}/v1/agents`, { signal: AbortSignal.timeout(2000) });
  assert.equal(unauthenticated.status, 401);
  await unauthenticated.arrayBuffer();
  for (const id of [sender, recipient]) {
    const response = await fetch(`${runtime.url}/v1/agents/${id}`, {
      method: 'PUT', headers, body: JSON.stringify(agent(id)), signal: AbortSignal.timeout(2000),
    });
    assert.equal(response.status, 204);
  }
  const discovery = await fetch(`${runtime.url}/v1/agents`, { headers, signal: AbortSignal.timeout(2000) });
  assert.equal(discovery.status, 200);
  const page = await discovery.json();
  assert.deepEqual(Object.keys(page).sort(), ['agents', 'capturedAt', 'epoch', 'nextCursor', 'page', 'revision', 'snapshotId', 'total']);
  assert.match(page.epoch, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/);
  assert.match(page.snapshotId, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/);
  assert.match(page.revision, /^(?:0|[1-9][0-9]*)$/);
  assert.ok(Number.isSafeInteger(page.capturedAt));
  assert.equal(page.page, 0);
  assert.equal(page.nextCursor, null);
  assert.equal(page.total, 2);
  assert.deepEqual(page.agents.map(a => a.agentId), [sender, recipient]);
  const controller = new AbortController();
  t.after(() => controller.abort());
  const stream = await fetch(`${runtime.url}/v1/events?agentId=${recipient}`, {
    headers, signal: AbortSignal.any([controller.signal, AbortSignal.timeout(5000)]),
  });
  assert.equal(stream.status, 200);
  assert.equal(stream.headers.get('content-type'), 'text/event-stream');
  const reader = stream.body.getReader();
  const snapshot = await readEvent(reader, 'presence_snapshot', true);
  assert.deepEqual(Object.keys(snapshot).sort(), ['agents', 'capturedAt', 'chunk', 'epoch', 'final', 'revision', 'snapshotId', 'total']);
  assert.equal(snapshot.epoch, page.epoch);
  assert.equal(snapshot.chunk, 0);
  assert.equal(snapshot.final, true);
  assert.equal(snapshot.total, 2);
  assert.deepEqual(snapshot.agents.map(a => a.agentId), [sender, recipient]);
  const caughtUp = await readEvent(reader, 'presence_delta', true);
  assert.deepEqual(caughtUp, { epoch: snapshot.epoch, fromRevision: snapshot.revision,
    toRevision: snapshot.revision, caughtUp: true, changes: [] });
  const message = {
    id: '33333333-3333-4333-8333-333333333333', from: sender, to: recipient,
    kind: 'notice', body: 'packaged fixture notice',
  };
  const accepted = await fetch(`${runtime.url}/v1/messages`, {
    method: 'POST', headers, body: JSON.stringify(message), signal: AbortSignal.timeout(2000),
  });
  assert.equal(accepted.status, 202);
  assert.equal((await accepted.json()).state, 'accepted');
  const delivered = await readNotice(reader);
  assert.equal(delivered.id, message.id);
  assert.equal(delivered.body, message.body);
  await reader.cancel();
  controller.abort();
  await checkRuntimeIsolation(runtime);
  const started = Date.now();
  assert.equal(runtime.child.exitCode, null, 'hub must still be running before SIGTERM');
  assert.equal(runtime.child.signalCode, null);
  assert.equal(runtime.child.kill('SIGTERM'), true, 'SIGTERM must reach the running hub');
  const [code, signal] = await runtime.exited;
  assert.equal(signal, null);
  assert.equal(code, 0);
  assert.ok(Date.now() - started < 5000, 'SIGTERM exceeded five seconds');
});

for (const streamCount of [1, 3, 8, 16]) {
test(`packaged SIGTERM cancels ${streamCount} active SSE streams with offline mail within five seconds`, { timeout: 20000 }, async t => {
  const runtime = await start(t, token);
  // One-shot events only, bounded by the fixture's stream count.
  // Never include payloads, stdio or process state.
  const timings = [];
  const mark = phase => timings.push({ phase, at: performance.now() });
  runtime.child.once('exit', () => mark('child-exit'));
  runtime.child.once('close', () => mark('child-close'));
  await ready(runtime);
  const ids = [sender, ...Array.from({ length: streamCount }, (_, index) =>
    `${(index + 10).toString(16).padStart(8, '0')}-1111-4111-8111-111111111111`)];
  for (const id of ids) {
    const response = await fetch(`${runtime.url}/v1/agents/${id}`, {
      method: 'PUT', headers, body: JSON.stringify(agent(id)), signal: AbortSignal.timeout(2000),
    });
    assert.equal(response.status, 204);
  }
  const streams = [];
  for (const id of ids.slice(0, streamCount)) {
    // Do not echo FIN or close locally when Cowboy shuts down its write side.
    const socket = createConnection({ host: '127.0.0.1', port: runtime.port, allowHalfOpen: true });
    t.after(() => socket.destroy());
    const ordinal = streams.length + 1;
    socket.once('end', () => mark(`socket-${ordinal}-eof`));
    const ended = once(socket, 'end');
    await once(socket, 'connect');
    const snapshot = new Promise((resolve, reject) => {
      let data = '';
      socket.on('data', chunk => {
        data += chunk.toString();
        if (data.includes('event: presence_snapshot') && data.includes('"final":true')) resolve();
      });
      socket.on('error', reject);
    });
    socket.write(`GET /v1/events?agentId=${id} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer ${token}\r\n\r\n`);
    await snapshot;
    streams.push({ socket, ended });
  }
  const accepted = await fetch(`${runtime.url}/v1/messages`, {
    method: 'POST', headers, signal: AbortSignal.timeout(2000),
    body: JSON.stringify({ id: '55555555-5555-4555-8555-555555555555',
      from: sender, to: ids[streamCount], kind: 'notice', body: 'offline during shutdown' }),
  });
  assert.equal(accepted.status, 202);
  assert.equal((await accepted.json()).receiving, false);
  const started = performance.now();
  timings.push({ phase: 'sigterm', at: started });
  let cleanupTimer;
  const cleanupDeadline = new Promise((_, reject) => {
    cleanupTimer = setTimeout(() => {
      reject(new Error('active SSE shutdown reached independent ten-second cleanup deadline'));
      if (runtime.child.exitCode === null && runtime.child.signalCode === null) {
        runtime.child.kill('SIGKILL');
      }
      for (const { socket } of streams) socket.destroy();
    }, 10000);
  });
  try {
    assert.equal(runtime.child.kill('SIGTERM'), true);
    await Promise.race([cleanupDeadline, (async () => {
      const [code, signal] = await runtime.exited;
      assert.equal(signal, null, 'ordinary stop must not require OS SIGKILL');
      assert.equal(code, 0);
      assert.ok(performance.now() - started < 5000, 'active SSE shutdown exceeded five seconds');
      await Promise.all(streams.map(({ ended }) => ended));
      for (const { socket } of streams) assert.equal(socket.writableEnded, false, 'no client-assisted close');
    })()]);
  } finally {
    clearTimeout(cleanupTimer);
    for (const { phase, at } of timings) {
      t.diagnostic(JSON.stringify({ phase, elapsedMs: Number((at - started).toFixed(3)) }));
    }
  }
});

}

test('packaged listener preserves mail and dedup; store restart loses volatile state', { timeout: 30000 }, async t => {
  const runtime = await start(t, token);
  await ready(runtime);
  const register = async () => {
    for (const id of [sender, recipient]) {
      const response = await fetch(`${runtime.url}/v1/agents/${id}`, {
        method: 'PUT', headers, body: JSON.stringify(agent(id)), signal: AbortSignal.timeout(2000),
      });
      assert.equal(response.status, 204);
    }
  };
  const send = async message => {
    const response = await fetch(`${runtime.url}/v1/messages`, {
      method: 'POST', headers, body: JSON.stringify(message), signal: AbortSignal.timeout(2000),
    });
    assert.equal(response.status, 202);
    return response.json();
  };
  const discover = async () => {
    const response = await fetch(`${runtime.url}/v1/agents`, { headers, signal: AbortSignal.timeout(2000) });
    assert.equal(response.status, 200);
    return (await response.json()).agents;
  };
  await register();
  const message = {
    id: '33333333-3333-4333-8333-333333333333', from: sender, to: recipient,
    kind: 'notice', body: 'survives packaged listener restart',
  };
  const acceptance = await send(message);
  await injectFault(runtime, 'listener');
  assert.deepEqual(new Set((await discover()).map(a => a.agentId)), new Set([sender, recipient]));
  assert.deepEqual(await send(message), acceptance, 'listener restart preserves original dedup acceptance');
  const controller = new AbortController();
  t.after(() => controller.abort());
  const stream = await fetch(`${runtime.url}/v1/events?agentId=${recipient}`, {
    headers, signal: AbortSignal.any([controller.signal, AbortSignal.timeout(5000)]),
  });
  assert.equal(stream.status, 200);
  const reader = stream.body.getReader();
  const delivered = await readNotice(reader);
  assert.equal(delivered.id, message.id);
  assert.equal(delivered.body, message.body, 'pending mail survives listener restart');
  await reader.cancel();
  controller.abort();
  const offlineDeadline = Date.now() + 2000;
  let offline = false;
  while (!offline && Date.now() < offlineDeadline) {
    offline = (await discover()).find(a => a.agentId === recipient)?.receiving === false;
    if (!offline) await delay(10);
  }
  assert.equal(offline, true, 'old stream must be detached before queuing pending mail');
  const lost = { ...message, id: '44444444-4444-4444-8444-444444444444', body: 'pending at store failure' };
  assert.equal((await send(lost)).receiving, false);
  await injectFault(runtime, 'store');
  assert.deepEqual(await discover(), [], 'store restart discards presence');
  await register();
  const changed = await send({ ...message, body: 'same ID, new payload after store restart' });
  assert.equal(changed.state, 'accepted', 'store restart loses old digest, rather than returning conflict');
  const freshController = new AbortController();
  t.after(() => freshController.abort());
  const freshStream = await fetch(`${runtime.url}/v1/events?agentId=${recipient}`, {
    headers, signal: AbortSignal.any([freshController.signal, AbortSignal.timeout(5000)]),
  });
  assert.equal(freshStream.status, 200);
  const freshReader = freshStream.body.getReader();
  // In the FIFO, retained old mail would precede this newly accepted marker.
  const fresh = await readNotice(freshReader);
  assert.equal(fresh.id, message.id, 'pending pre-restart mail must not survive ahead of fresh mail');
  assert.equal(fresh.body, 'same ID, new payload after store restart');
  await freshReader.cancel();
  freshController.abort();
});
