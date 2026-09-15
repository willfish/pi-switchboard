import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { LIMITS, cursorFor, decodePage, isAgent, createStage, discover } from '../hub/priv/dashboard/protocol.js';

const fixture = JSON.parse(await readFile(new URL('./fixtures/register-valid.json', import.meta.url), 'utf8'));
const id = (n) => `${n.toString(16).padStart(8, '0')}-0000-0000-0000-000000000000`;
const agent = (n = 1) => ({ ...fixture, agentId: id(n), receiving: false, updatedAt: 1770000000 });
const page = (agents = [], extra = {}) => ({ epoch: id(9000), snapshotId: id(9001), revision: '18446744073709551615', capturedAt: 1770000000, page: 0, total: agents.length, agents, nextCursor: null, ...extra });
const bytes = (p) => new TextEncoder().encode(JSON.stringify(p));
const response = (p) => new Response(bytes(p));
const rejectsCode = (promise, code) => assert.rejects(promise, (e) => e.code === code);

test('shared registration fixture becomes exact public presence; hostile text remains literal data', () => {
  const a = agent();
  assert.equal(isAgent(a), true);
  a.label = '<img src=x onerror=alert(1)>\u202eTEXT'; a.model = null;
  assert.deepEqual(decodePage(bytes(page([a]))).agents, [a]);
  for (const patch of [{ receiving: 1 }, { extra: true }, { pid: 0 }, { label: '\u0000' },
    { cwd: 'x'.repeat(4097) }, { model: { provider: 'x', id: 'y', extra: true } },
    { sessionId: 'bad' }, { updatedAt: -1 }, { label: '\ud800' }, { host: 'é' },
    { sessionName: 'a'.repeat(201) }, { status: 'offline' }]) assert.equal(isAgent({ ...a, ...patch }), false);
});

test('fatal UTF-8, duplicate decoded keys, BOM, unknown fields and invalid revisions fail closed', () => {
  for (const raw of ['{"epoch":1,"epoch":2}', JSON.stringify(page()).replace('"page":0', '"page":0,"p\\u0061ge":0'),
    JSON.stringify(page({})), JSON.stringify(page([], { extra: 1 })), JSON.stringify(page([], { revision: '01' })),
    JSON.stringify(page([], { revision: '18446744073709551616' })), '\ufeff' + JSON.stringify(page())]) {
    assert.throws(() => decodePage(new TextEncoder().encode(raw)), /schema/);
  }
  assert.throws(() => decodePage(Uint8Array.of(0xff)), /schema/);
  assert.throws(() => decodePage(new Uint8Array(LIMITS.pageBytes + 1)), /limit/);
});

test('escaped duplicate keys are rejected at agent/model depth, not across independent objects', () => {
  const a = { ...agent(), model: { provider: 'synthetic', id: 'model' } };
  const raw = JSON.stringify(page([a]));
  for (const duplicate of [
    raw.replace('"label":', '"l\\u0061bel":"duplicate","label":'),
    raw.replace('"provider":', '"prov\\u0069der":"duplicate","provider":'),
    raw.replace('"id":"model"', '"id":"model","\\u0069d":"duplicate"'),
  ]) assert.throws(() => decodePage(new TextEncoder().encode(duplicate)), /schema/);
  const punctuation = '\\"label\\": { [ ] } , : \\\\ end';
  const independent = page([a, { ...a, agentId: id(2), label: punctuation,
    model: { provider: punctuation, id: punctuation } }]);
  assert.deepEqual(decodePage(bytes(independent)), independent);
});

test('exact sequential snapshot stage rejects mixed pages, duplicates, empty continuation, counts and cursor changes', () => {
  const first = page([agent(1)], { total: 2, nextCursor: cursorFor(id(9001), 1) });
  for (const patch of [{ epoch: id(8) }, { revision: '2' }, { snapshotId: id(7) }, { capturedAt: 1 },
    { total: 3 }, { page: 2 }, { agents: [agent(1)] }, { agents: [] }, { nextCursor: 'bad' }]) {
    const stage = createStage(); stage.add(first, bytes(first).length);
    assert.throws(() => stage.add(page([agent(2)], { total: 2, page: 1, ...patch }), 100));
    assert.throws(() => stage.finish());
  }
  assert.throws(() => createStage().add(page([], { total: 2, nextCursor: cursorFor(id(9001), 1) }), 100));
  assert.throws(() => createStage().add(page([agent(2), agent(1)]), 100));
  assert.throws(() => createStage().add(page([agent()], { total: 5001 }), 100));
  assert.throws(() => createStage().add(page(Array.from({ length: 129 }, (_, i) => agent(i))), 100));
  const empty = createStage(); empty.add(page(), 100); assert.deepEqual(empty.finish().agents, []);
});

test('legacy discovery cannot be redirected by path or header overrides', async () => {
  let calls = 0;
  await discover('synthetic-only', {
    path: '/dashboard/api/v1/presence',
    headers: { 'X-Switchboard-Session': 'nope', Authorization: 'Bearer hostile' },
    fetch: async (url, options) => {
      assert.equal(url, '/v1/agents');
      assert.deepEqual(options.headers, { Authorization: 'Bearer synthetic-only' });
      calls += 1;
      return response(page());
    },
  });
  assert.equal(calls, 1);
});

test('GET-only fixed same-origin transport stages 5000 records atomically', async () => {
  let calls = 0;
  const result = await discover('synthetic-only', { fetch: async (url, options) => {
    assert.equal(options.method, 'GET'); assert.equal(options.credentials, 'omit'); assert.equal(options.redirect, 'error');
    assert.equal(options.cache, 'no-store'); assert.equal(options.mode, 'same-origin'); assert.equal(options.referrerPolicy, 'no-referrer');
    assert.deepEqual(options.headers, { Authorization: 'Bearer synthetic-only' });
    assert.equal(url, calls === 0 ? '/v1/agents' : `/v1/agents?cursor=${cursorFor(id(9001), calls)}`);
    const start = calls * 128, n = Math.min(128, 5000 - start);
    const p = page(Array.from({ length: n }, (_, i) => agent(start + i)), { page: calls, total: 5000,
      nextCursor: start + n === 5000 ? null : cursorFor(id(9001), calls + 1) });
    calls += 1; return response(p);
  } });
  assert.equal(calls, 40); assert.equal(result.agents.length, 5000);
});

test('409 or changed identity after first page never returns partial data', async () => {
  for (const status of [409, 401, 500]) {
    let calls = 0;
    await rejectsCode(discover('synthetic', { fetch: async () => ++calls === 1
      ? response(page([agent()], { total: 2, nextCursor: cursorFor(id(9001), 1) })) : new Response(null, { status }) }),
    status === 409 ? 'reset' : status === 401 ? 'unauthorized' : 'transport');
    assert.equal(calls, 2);
  }
});

test('stream bounds do not trust content-length; chunked UTF-8 is decoded only when complete', async () => {
  const data = bytes(page([ { ...agent(), label: 'λ🪷' } ]));
  const result = await discover('synthetic', { fetch: async () => new Response(new ReadableStream({ start(c) {
    for (const b of data) c.enqueue(Uint8Array.of(b)); c.close();
  } })) });
  assert.equal(result.agents[0].label, 'λ🪷');
  await rejectsCode(discover('synthetic', { fetch: async () => new Response(new ReadableStream({ start(c) {
    c.enqueue(new Uint8Array(LIMITS.pageBytes)); c.enqueue(Uint8Array.of(0)); c.close();
  } }), { headers: { 'Content-Length': '1' } }) }), 'limit');
});

test('valid traversal above 32 MiB and refusal above 256 MiB use streamed generated pages', async () => {
  async function run(total) {
    let n = 0;
    const promise = discover('synthetic', { fetch: async () => {
      const p = page([agent(n + 1)], { page: n, total, nextCursor: n + 1 === total ? null : cursorFor(id(9001), n + 1) });
      n += 1;
      const encoded = bytes(p);
      return new Response(new ReadableStream({ start(c) {
        c.enqueue(new Uint8Array(LIMITS.pageBytes - encoded.length).fill(32)); c.enqueue(encoded); c.close();
      } }));
    } });
    return { promise, calls: () => n };
  }
  const valid = await run(34); assert.equal((await valid.promise).agents.length, 34); assert.equal(valid.calls(), 34);
  const maximum = await run(256); assert.equal((await maximum.promise).agents.length, 256);
  const over = await run(257); await rejectsCode(over.promise, 'limit'); assert.equal(over.calls(), 257);
});

test('abort and deadlines fence uncooperative fetch and stalled body reads', async () => {
  const external = new AbortController(); let resolve;
  const pending = discover('synthetic', { signal: external.signal, fetch: () => new Promise((r) => { resolve = r; }) });
  external.abort(); await rejectsCode(pending, 'cancelled'); resolve(response(page()));
  for (const body of [false, true]) {
    const timers = new Map(); let serial = 0;
    const p = discover('synthetic', { fetch: async () => body ? new Response(new ReadableStream()) : new Promise(() => {}),
      setTimer(fn, ms) { const k = ++serial; timers.set(k, { fn, ms }); return k; }, clearTimer(k) { timers.delete(k); } });
    await Promise.resolve(); await Promise.resolve();
    [...timers.values()].find((t) => t.ms === 5000).fn();
    await rejectsCode(p, 'timeout'); assert.equal(timers.size, 0);
  }
});

test('absolute overall and per-request checks reject late completions even without timer dispatch', async () => {
  for (const elapsed of [5000, 30000]) {
    let clock = 0;
    await rejectsCode(discover('synthetic', { now: () => clock, fetch: async () => { clock = elapsed; return response(page()); } }), 'timeout');
  }
});
