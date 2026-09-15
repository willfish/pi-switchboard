import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { LIMITS, cursorFor, DiscoveryError } from '../hub/priv/dashboard/protocol.js';
import { createOperatorSession } from '../hub/priv/dashboard/operator-session.js';

const fixture = JSON.parse(await readFile(new URL('./fixtures/register-valid.json', import.meta.url), 'utf8'));
const id = (n) => `${n.toString(16).padStart(8, '0')}-0000-0000-0000-000000000000`;
const hex = (n = 1) => n.toString(16).padStart(64, '0');
const agent = (n = 1) => ({ ...fixture, agentId: id(n), receiving: false, updatedAt: 1770000000 });
const page = (agents = [], extra = {}) => ({ epoch: id(9000), snapshotId: id(9001), revision: '1',
  capturedAt: 1770000000, page: 0, total: agents.length, agents, nextCursor: null, ...extra });
const bytes = (p) => new TextEncoder().encode(typeof p === 'string' ? p : JSON.stringify(p));
const response = (p, status = 200) => new Response(bytes(p), { status });
const empty = () => new Response(null, { status: 204 });
const rejectsCode = (promise, code) => assert.rejects(promise, (e) => e instanceof DiscoveryError && e.code === code);
const settle = async () => { for (let n = 0; n < 20; n++) await Promise.resolve(); };
const transport = (options) => {
  assert.equal(options.mode, 'same-origin');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.redirect, 'error');
  assert.equal(options.cache, 'no-store');
};

function publicLeak(states, secret) {
  return JSON.stringify(states).includes(secret);
}

function session(handler) {
  const calls = [], states = [], timers = new Map();
  let serial = 0;
  const controller = createOperatorSession({
    fetch: async (url, options) => {
      transport(options);
      const recorded = { url, options };
      calls.push(recorded);
      return handler(recorded, calls);
    },
    render: (s) => states.push(s),
    setTimer(fn, ms) { const k = ++serial; timers.set(k, { fn, ms }); return k; },
    clearTimer(k) { timers.delete(k); },
  });
  return { controller, calls, states, timers, state: () => states.at(-1) };
}

test('403 distinguishes explicit disabled from other denial without reflecting server messages', async () => {
  for (const [code, expected] of [['disabled', 'disabled'], ['forbidden', 'forbidden'], ['unknown', 'forbidden']]) {
    const h = session(async () => response({ error: { code, message: 'private error sentinel' } }, 403));
    await rejectsCode(h.controller.connect(), expected);
    assert.equal(h.state().status, 'failed');
    assert.equal(h.state().snapshot, null);
    assert.doesNotMatch(h.state().error, /private error sentinel/);
  }
  const h = session(async () => new Response(null, { status: 403 }));
  await rejectsCode(h.controller.connect(), 'forbidden');
  const duplicate = session(async () => response('{"error":{"code":"forbidden","code":"disabled","message":"private"}}', 403));
  await rejectsCode(duplicate.controller.connect(), 'forbidden');
  const oversized = session(async () => response('x'.repeat(2049), 403));
  await rejectsCode(oversized.controller.connect(), 'limit');
});

test('factory does no network and public state never includes the nonce', () => {
  let calls = 0;
  const states = [];
  createOperatorSession({
    fetch: async () => { calls += 1; throw new Error('network'); },
    render: (s) => states.push(s),
  });
  assert.equal(calls, 0);
  assert.equal(states.length, 1);
  assert.equal(states[0].status, 'disconnected');
  assert.equal(states[0].snapshot, null);
  assert.equal(Object.hasOwn(states[0], 'nonce'), false);
  assert.equal(Object.hasOwn(states[0], 'session'), false);
  assert.equal(Object.hasOwn(states[0], 'token'), false);
});

test('concurrent connect single-flights one exact empty bootstrap POST', async () => {
  let resolve, started = 0;
  const pending = new Promise((r) => { resolve = r; });
  const h = session(async ({ url, options }) => {
    started += 1;
    assert.equal(url, '/dashboard/api/v1/session');
    assert.equal(options.method, 'POST');
    assert.equal(options.body, '{}');
    assert.deepEqual(options.headers, { 'content-type': 'application/json' });
    assert.equal(options.headers.Authorization, undefined);
    assert.equal(options.headers['X-Switchboard-Session'], undefined);
    await pending;
    return response({ session: hex() });
  });
  const a = h.controller.connect();
  const b = h.controller.connect();
  await settle();
  assert.equal(started, 1);
  assert.equal(h.state().status, 'connecting');
  resolve();
  await Promise.all([a, b]);
  assert.equal(h.calls.length, 1);
  assert.equal(h.state().status, 'connected');
  assert.equal(publicLeak(h.states, hex()), false);
});

test('malformed, duplicate-key, uppercase, BOM and oversized bootstrap responses fail closed', async () => {
  const secret = 'abcdef0123456789'.repeat(4);
  for (const body of [
    `{"session":"${secret}","session":"${secret}"}`,
    JSON.stringify({ session: secret }).replace('"session":', '"s\\u0065ssion":"duplicate","session":'),
    JSON.stringify({ session: secret.toUpperCase() }),
    JSON.stringify({ session: secret, extra: true }),
    JSON.stringify({ session: secret.slice(1) }),
    '\ufeff' + JSON.stringify({ session: secret }),
    '[]', 'null', '"abc"', '{',
  ]) {
    const h = session(async () => new Response(bytes(body)));
    await rejectsCode(h.controller.connect(), 'schema');
    assert.equal(h.state().status, 'failed');
    assert.equal(publicLeak(h.states, secret), false);
    assert.equal(String(h.state().error).includes(secret), false);
  }
  const h = session(async () => new Response(new ReadableStream({ start(c) {
    c.enqueue(new Uint8Array(2048)); c.enqueue(Uint8Array.of(0)); c.close();
  } })));
  await rejectsCode(h.controller.connect(), 'limit');
});

test('timeout and abort fence uncooperative bootstrap even when fetch ignores the signal', async () => {
  const external = new AbortController();
  let resolve;
  const h = session(() => new Promise((r) => { resolve = r; }));
  const pending = h.controller.connect({ signal: external.signal });
  external.abort();
  await rejectsCode(pending, 'cancelled');
  resolve(response({ session: hex() }));
  await settle();
  assert.equal(h.state().status, 'failed');
  assert.equal(publicLeak(h.states, hex()), false);
  for (const body of [false, true]) {
    const t = session(async () => body ? new Response(new ReadableStream()) : new Promise(() => {}));
    const p = t.controller.connect();
    await settle();
    [...t.timers.values()].find((timer) => timer.ms === 5000).fn();
    await rejectsCode(p, 'timeout');
    assert.equal(t.timers.size, 0);
  }
  let clock = 0;
  const late = createOperatorSession({
    now: () => clock,
    fetch: async (url, options) => { transport(options); clock = 5000; return response({ session: hex() }); },
    render: () => {},
  });
  await rejectsCode(late.connect(), 'timeout');
});

test('operator paths never send the nonce as Authorization, cookies, query or legacy agents', async () => {
  const secret = hex(3);
  const h = session(async ({ url, options }) => {
    assert.match(url, /^\/dashboard\/api\/v1\/(session|presence|disconnect)(\?cursor=[A-Za-z0-9_-]+)?$/);
    assert.equal(url.includes(secret), false);
    assert.equal(url.includes('/v1/agents'), false);
    assert.equal(options.headers.Authorization, undefined);
    assert.equal(options.headers.authorization, undefined);
    assert.equal(options.headers.Cookie, undefined);
    assert.equal(options.headers.cookie, undefined);
    assert.equal(options.headers.Origin, undefined);
    if (url === '/dashboard/api/v1/session') {
      assert.deepEqual(options.headers, { 'content-type': 'application/json' });
      return response({ session: secret });
    }
    if (url.startsWith('/dashboard/api/v1/presence')) {
      assert.equal(options.method, 'GET');
      assert.deepEqual(options.headers, { 'X-Switchboard-Session': secret });
      return response(page([agent()]));
    }
    assert.equal(url, '/dashboard/api/v1/disconnect');
    assert.equal(options.method, 'POST');
    assert.equal(options.body, '{}');
    assert.deepEqual(options.headers, { 'content-type': 'application/json', 'X-Switchboard-Session': secret });
    return empty();
  });
  await h.controller.connect();
  const snapshot = await h.controller.presence();
  assert.equal(snapshot.agents.length, 1);
  await h.controller.disconnect();
  assert.equal(h.calls.map((c) => c.url).join(','),
    '/dashboard/api/v1/session,/dashboard/api/v1/presence,/dashboard/api/v1/disconnect');
  assert.equal(publicLeak(h.states, secret), false);
});

test('reads reconnect once after 401 with fresh staging; mutations are never retried', async () => {
  const first = hex(4), second = hex(5);
  const pages = [];
  const h = session(async ({ url, options }) => {
    if (url === '/dashboard/api/v1/session') {
      const issued = options.headers['X-Switchboard-Session'] ? 'tagged' : (h.calls.filter((c) => c.url.endsWith('/session')).length === 1 ? first : second);
      return response({ session: issued === 'tagged' ? 'error' : issued });
    }
    if (url.startsWith('/dashboard/api/v1/presence')) {
      const nonce = options.headers['X-Switchboard-Session'];
      if (nonce === first && !url.includes('cursor=')) {
        pages.push('partial');
        return response(page([agent(1)], { total: 2, nextCursor: cursorFor(id(9001), 1) }));
      }
      if (nonce === first) return new Response(null, { status: 401 });
      assert.equal(nonce, second);
      assert.equal(url.includes('cursor='), false);
      pages.push('fresh');
      return response(page([agent(2)]));
    }
    return new Response(null, { status: 500 });
  });
  await h.controller.connect();
  const snapshot = await h.controller.presence();
  assert.equal(snapshot.agents.length, 1);
  assert.equal(snapshot.agents[0].agentId, id(2));
  assert.deepEqual(pages, ['partial', 'fresh']);
  assert.equal(h.calls.filter((c) => c.url === '/dashboard/api/v1/session').length, 2);
  assert.equal(h.calls.some((c) => c.options.headers.Authorization), false);
  const failed = session(async ({ url }) => {
    if (url.endsWith('/session')) return response({ session: hex(6) });
    return new Response(null, { status: 401 });
  });
  await failed.controller.connect();
  await rejectsCode(failed.controller.presence(), 'unauthorized');
  assert.equal(failed.calls.filter((c) => c.url.endsWith('/session')).length, 2);
  assert.equal(failed.state().status, 'failed');
  assert.equal(failed.state().snapshot, null);
  await rejectsCode(failed.controller.presence(), 'unauthorized');
  assert.equal(failed.calls.filter((c) => c.url.endsWith('/session')).length, 4);
  const disc = session(async ({ url }) => {
    if (url.endsWith('/session')) return response({ session: hex(7) });
    return new Response(null, { status: 500 });
  });
  await disc.controller.connect();
  await disc.controller.disconnect();
  assert.equal(disc.calls.filter((c) => c.url.endsWith('/disconnect')).length, 1);
  assert.equal(disc.state().invalidation, 'unknown');
  assert.equal(disc.state().status, 'disconnected');
});

test('explicit disconnect clears immediately, stays down, fences stale results and reports invalidation', async () => {
  const secret = hex(8);
  let resolveBootstrap, resolvePresence, resolveDisconnect;
  const bootstrap = new Promise((r) => { resolveBootstrap = r; });
  const presenceHold = new Promise((r) => { resolvePresence = r; });
  const disconnectHold = new Promise((r) => { resolveDisconnect = r; });
  const h = session(async ({ url }) => {
    if (url.endsWith('/session')) { await bootstrap; return response({ session: secret }); }
    if (url.startsWith('/dashboard/api/v1/presence')) {
      await presenceHold; return response(page([agent()]));
    }
    await disconnectHold; return empty();
  });
  const connected = h.controller.connect();
  resolveBootstrap();
  await connected;
  const latePresence = h.controller.presence();
  await settle();
  const disconnecting = h.controller.disconnect();
  assert.equal(h.state().status, 'disconnected');
  assert.equal(h.state().snapshot, null);
  assert.equal(publicLeak(h.states, secret), false);
  resolvePresence();
  await rejectsCode(latePresence, 'cancelled');
  assert.equal(h.state().snapshot, null);
  await settle();
  const presenceCalls = h.calls.filter((c) => c.url.startsWith('/dashboard/api/v1/presence')).length;
  assert.equal(presenceCalls, 1);
  void h.controller.presence().catch(() => {});
  await settle();
  assert.equal(h.calls.filter((c) => c.url.startsWith('/dashboard/api/v1/presence')).length, presenceCalls);
  resolveDisconnect();
  await disconnecting;
  assert.equal(h.state().invalidation, 'complete');
  assert.equal(h.state().status, 'disconnected');
  const reconnect = session(async ({ url }) => {
    if (url.endsWith('/session')) return response({ session: hex(9) });
    if (url.startsWith('/dashboard/api/v1/presence')) return response(page());
    return empty();
  });
  await reconnect.controller.connect();
  await reconnect.controller.presence();
  assert.equal(reconnect.state().status, 'connected');
});

test('presence is single-flight, concurrent 401s recover once, and a failed read clears snapshot', async () => {
  const first = hex(10), second = hex(11);
  let presenceWaits = [];
  const h = session(async ({ url, options }) => {
    if (url === '/dashboard/api/v1/session') {
      return response({ session: h.calls.filter((c) => c.url.endsWith('/session')).length === 1 ? first : second });
    }
    if (url.startsWith('/dashboard/api/v1/presence')) {
      const nonce = options.headers['X-Switchboard-Session'];
      if (nonce === first) return new Response(null, { status: 401 });
      const hold = new Promise((r) => presenceWaits.push(r));
      await hold;
      return response(page([agent(3)]));
    }
    return empty();
  });
  await h.controller.connect();
  const a = h.controller.presence();
  const b = h.controller.presence();
  for (let n = 0; n < 50 && presenceWaits.length === 0; n++) await Promise.resolve();
  assert.equal(h.calls.filter((c) => c.url.endsWith('/session')).length, 2);
  assert.equal(h.calls.filter((c) => c.url.startsWith('/dashboard/api/v1/presence')).length, 2);
  assert.equal(presenceWaits.length, 1);
  presenceWaits[0]();
  const [left, right] = await Promise.all([a, b]);
  assert.equal(left, right);
  assert.equal(left.agents[0].agentId, id(3));
  assert.equal(publicLeak(h.states, first), false);
  assert.equal(publicLeak(h.states, second), false);
  const broken = session(async ({ url }) => {
    if (url.endsWith('/session')) return response({ session: hex(12) });
    if (url.startsWith('/dashboard/api/v1/presence')) {
      if (broken.calls.filter((c) => c.url.startsWith('/dashboard/api/v1/presence')).length === 1) {
        return response(page([agent(4)]));
      }
      return new Response(null, { status: 500 });
    }
    return empty();
  });
  await broken.controller.connect();
  await broken.controller.presence();
  assert.equal(broken.state().status, 'connected');
  assert.equal(broken.state().snapshot.agents.length, 1);
  await rejectsCode(broken.controller.presence(), 'transport');
  assert.equal(broken.state().snapshot, null);
  assert.equal(broken.state().status, 'failed');
  assert.equal(publicLeak(broken.states, hex(12)), false);
});

test('ignored abort after await does not publish; recovery bootstrap failure is failed and later read reconnects', async () => {
  const secret = hex(13);
  let unblock;
  const external = new AbortController();
  const h = session(() => new Promise((r) => { unblock = r; }));
  const pending = h.controller.connect({ signal: external.signal });
  await settle();
  unblock(response({ session: secret }));
  external.abort();
  await rejectsCode(pending, 'cancelled');
  assert.notEqual(h.state().status, 'connected');
  assert.equal(publicLeak(h.states, secret), false);
  const recover = session(async ({ url, options }) => {
    const sessions = recover.calls.filter((c) => c.url.endsWith('/session')).length;
    if (url.endsWith('/session')) {
      if (sessions === 1) return response({ session: hex(14) });
      if (sessions === 2) return new Response(bytes('{'));
      return response({ session: hex(15) });
    }
    if (url.startsWith('/dashboard/api/v1/presence')) {
      if (options.headers['X-Switchboard-Session'] === hex(15)) return response(page([agent(5)]));
      return new Response(null, { status: 401 });
    }
    return empty();
  });
  await recover.controller.connect();
  await rejectsCode(recover.controller.presence(), 'schema');
  assert.equal(recover.state().status, 'failed');
  assert.equal(recover.state().snapshot, null);
  assert.equal(publicLeak(recover.states, hex(14)), false);
  const snapshot = await recover.controller.presence();
  assert.equal(snapshot.agents[0].agentId, id(5));
  assert.equal(recover.state().status, 'connected');
  assert.equal(recover.calls.filter((c) => c.url.endsWith('/session')).length, 3);
  await recover.controller.disconnect();
  await rejectsCode(recover.controller.presence(), 'disconnected');
  assert.equal(recover.calls.filter((c) => c.url.endsWith('/session')).length, 3);
});

test('reconnect clears invalidation; disconnect during bootstrap reports unknown invalidation', async () => {
  const secret = hex(16);
  let release;
  const held = new Promise((r) => { release = r; });
  const h = session(async ({ url }) => {
    if (url.endsWith('/session')) { await held; return response({ session: secret }); }
    return empty();
  });
  const connecting = h.controller.connect();
  await settle();
  const disconnecting = h.controller.disconnect();
  assert.equal(h.state().status, 'disconnected');
  assert.equal(h.state().invalidation, 'unknown');
  assert.equal(h.calls.filter((c) => c.url.endsWith('/disconnect')).length, 0);
  release();
  await rejectsCode(connecting, 'cancelled');
  await disconnecting;
  assert.equal(h.state().invalidation, 'unknown');
  assert.equal(h.state().status, 'disconnected');
  assert.equal(publicLeak(h.states, secret), false);
  const round = session(async ({ url }) => {
    if (url.endsWith('/session')) return response({ session: hex(17) });
    if (url.startsWith('/dashboard/api/v1/presence')) return response(page());
    return empty();
  });
  await round.controller.connect();
  await round.controller.disconnect();
  assert.equal(round.state().invalidation, 'complete');
  await round.controller.connect();
  assert.equal(round.state().invalidation, null);
  assert.equal(round.state().status, 'connected');
  assert.equal(publicLeak(round.states, hex(17)), false);
});

test('old presence waiting on connect cancels across disconnect and explicit reconnect', async () => {
  const first = hex(18), second = hex(19);
  let releaseFirst;
  const firstHold = new Promise((r) => { releaseFirst = r; });
  const h = session(async ({ url, options }) => {
    if (url.endsWith('/session')) {
      if (h.calls.filter((c) => c.url.endsWith('/session')).length === 1) {
        await firstHold; return response({ session: first });
      }
      return response({ session: second });
    }
    if (url.startsWith('/dashboard/api/v1/presence')) {
      assert.equal(options.headers['X-Switchboard-Session'], second);
      return response(page([agent(6)]));
    }
    return empty();
  });
  const connecting = h.controller.connect();
  const stalePresence = h.controller.presence();
  await settle();
  await h.controller.disconnect();
  assert.equal(h.state().status, 'disconnected');
  await h.controller.connect();
  const fresh = h.controller.presence();
  releaseFirst();
  await rejectsCode(connecting, 'cancelled');
  await rejectsCode(stalePresence, 'cancelled');
  const snapshot = await fresh;
  assert.equal(snapshot.agents[0].agentId, id(6));
  assert.equal(h.state().status, 'connected');
  assert.equal(h.state().snapshot.agents[0].agentId, id(6));
  assert.equal(publicLeak(h.states, first), false);
  assert.equal(h.calls.some((c) => c.options.headers['X-Switchboard-Session'] === first), false);
});

test('disconnect during held 401 recovery reports unknown and does not follow the new session', async () => {
  const first = hex(20), second = hex(21);
  let releaseRecovery;
  const recoveryHold = new Promise((r) => { releaseRecovery = r; });
  const h = session(async ({ url, options }) => {
    if (url.endsWith('/session')) {
      if (h.calls.filter((c) => c.url.endsWith('/session')).length === 1) return response({ session: first });
      await recoveryHold; return response({ session: second });
    }
    if (url.startsWith('/dashboard/api/v1/presence')) {
      if (options.headers['X-Switchboard-Session'] === first) return new Response(null, { status: 401 });
      return response(page([agent(7)]));
    }
    return empty();
  });
  await h.controller.connect();
  const pending = h.controller.presence();
  for (let n = 0; n < 50 && h.calls.filter((c) => c.url.endsWith('/session')).length < 2; n++) await Promise.resolve();
  assert.equal(h.calls.filter((c) => c.url.endsWith('/session')).length, 2);
  const disconnecting = h.controller.disconnect();
  assert.equal(h.state().status, 'disconnected');
  assert.equal(h.state().invalidation, 'unknown');
  assert.equal(h.state().snapshot, null);
  releaseRecovery();
  await rejectsCode(pending, 'cancelled');
  await disconnecting;
  assert.equal(h.state().invalidation, 'unknown');
  assert.equal(h.calls.filter((c) => c.url.endsWith('/disconnect')).length, 0);
  assert.equal(publicLeak(h.states, first), false);
  assert.equal(publicLeak(h.states, second), false);
  const retained = session(async ({ url }) => {
    if (url.endsWith('/session')) {
      if (retained.calls.filter((c) => c.url.endsWith('/session')).length === 1) return response({ session: hex(22) });
      const hold = retained.hold; await hold; return response({ session: hex(23) });
    }
    if (url.startsWith('/dashboard/api/v1/presence')) {
      if (retained.calls.filter((c) => c.url.startsWith('/dashboard/api/v1/presence')).length === 1) {
        return response(page([agent(8)]));
      }
      return new Response(null, { status: 500 });
    }
    return empty();
  });
  let releaseNext;
  retained.hold = new Promise((r) => { releaseNext = r; });
  await retained.controller.connect();
  await retained.controller.presence();
  await rejectsCode(retained.controller.presence(), 'transport');
  assert.equal(retained.state().status, 'failed');
  const reconnecting = retained.controller.connect();
  await settle();
  const during = retained.controller.disconnect();
  assert.equal(retained.state().invalidation, 'unknown');
  assert.notEqual(retained.state().invalidation, 'complete');
  releaseNext();
  await rejectsCode(reconnecting, 'cancelled');
  await during;
  assert.equal(retained.state().invalidation, 'unknown');
  assert.equal(retained.state().status, 'disconnected');
  assert.equal(publicLeak(retained.states, hex(22)), false);
  assert.equal(publicLeak(retained.states, hex(23)), false);
});
