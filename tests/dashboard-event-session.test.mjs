import test from 'node:test';
import assert from 'node:assert/strict';
import { createOperatorSession } from '../hub/priv/dashboard/operator-session.js';
const epoch = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const nonce = 'a'.repeat(64);
const doc = { epoch, fromSequence: '0', toSequence: '0', retainedFrom: '0', coverage: 'empty', caughtUp: true, nextCursor: null, events: [] };
const response = (v, status = 200) => new Response(JSON.stringify(v), { status });
const turn = async () => { for (let n = 0; n < 30; n++) await Promise.resolve(); };
function fixture(handler) {
  const calls = [];
  const client = createOperatorSession({ fetch: async (url, options) => {
    calls.push({ url, options });
    assert.equal(options.credentials, 'omit'); assert.equal(options.redirect, 'error');
    assert.equal(options.mode, 'same-origin');
    if (url.endsWith('/session')) return response({ session: nonce });
    if (url.endsWith('/disconnect')) return new Response(null, { status: 204 });
    return handler(url, options);
  } });
  return { client, calls };
}
test('events use only fixed GET endpoint with private session header', async () => {
  const f = fixture(async (url, opts) => {
    assert.equal(url, '/dashboard/api/v1/events'); assert.equal(opts.method, 'GET');
    assert.equal(opts.headers['X-Switchboard-Session'], nonce);
    assert.equal(opts.headers.Authorization, undefined);
    return response(doc);
  });
  await f.client.connect(); assert.deepEqual(await f.client.events(), doc);
  assert.equal(f.calls.length, 2);
});
test('event reads coalesce same cursor but reject competing cursor and malformed query', async () => {
  let release; const held = new Promise(resolve => { release = resolve; });
  const f = fixture(async () => { await held; return response(doc); });
  await f.client.connect();
  const first = f.client.events(); assert.equal(f.client.events(), first);
  await assert.rejects(f.client.events('YWJj'), { code: 'busy' });
  release(); await first;
  await assert.rejects(f.client.events('?session=secret'), { code: 'schema' });
  assert.equal(f.calls.length, 2);
});
test('disconnect fences a late event read even if fetch ignores abort', async () => {
  let release; const held = new Promise(resolve => { release = resolve; });
  const f = fixture(async () => { await held; return response(doc); });
  await f.client.connect(); const pending = f.client.events();
  const rejected = assert.rejects(pending, { code: 'cancelled' });
  await turn(); await f.client.disconnect(); release(); await rejected;
  await assert.rejects(f.client.events(), { code: 'disconnected' });
});
test('events and presence serialize in either direction', async () => {
  const presence = { epoch, revision: '0', snapshotId: epoch, capturedAt: 1, page: 0, total: 0, agents: [], nextCursor: null };
  for (const order of [['events', 'presence'], ['presence', 'events']]) {
    let release; const held = new Promise(resolve => { release = resolve; }); let reads = 0;
    const f = fixture(async url => {
      reads++; if (reads === 1) await held;
      return response(url.endsWith('/events') ? doc : presence);
    });
    await f.client.connect(); const a = f.client[order[0]](); const b = f.client[order[1]]();
    await turn(); assert.equal(reads, 1); release(); await Promise.all([a, b]); assert.equal(reads, 2);
  }
});
test('expired session renews once; history gaps are not automatically replayed', async () => {
  let reads = 0;
  const f = fixture(async () => ++reads === 1 ? response({}, 401) : response(doc));
  await f.client.connect(); assert.deepEqual(await f.client.events(), doc);
  assert.equal(f.calls.filter(c => c.url.endsWith('/session')).length, 2);
  const gap = fixture(async () => response({ error: { code: 'history_lost', message: 'gap' } }, 409));
  await gap.client.connect(); await assert.rejects(gap.client.events(), { code: 'history' });
  assert.equal(gap.calls.length, 2);
});
test('untrusted malformed and oversized event responses fail closed', async () => {
  for (const v of [{ ...doc, token: 'not allowed' }, { text: 'x'.repeat(1048577) }]) {
    const f = fixture(async () => response(v)); await f.client.connect();
    await assert.rejects(f.client.events());
  }
});
