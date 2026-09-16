import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createOperatorSession } from '../hub/priv/dashboard/operator-session.js';
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const work = JSON.parse(readFileSync(new URL('./fixtures/operator-work.json', import.meta.url), 'utf8')).allNull;
const view = { binding: { schemaVersion: 1, agentId: id, sessionId: id, runtimeGeneration: '1', sessionGeneration: '1',
  branchId: null, activeRunId: null, registration: { epoch: id, generation: '1' }, permissionRevision: '0', reportRevision: '1',
  capabilities: ['work.report.v1'], bindingId: id, workRevision: '1' }, work,
  permissions: { notice: false, work: false, guidance: false, sessionRead: false, label: false, interrupt: false, content: false, workAssign: false, history: false } };
test('work read uses fixed selected-runtime path and private nonce', async () => {
  let reads = 0;
  const session = createOperatorSession({ fetch: async (url, options) => {
    if (url.endsWith('/session')) return new Response(JSON.stringify({ session: 'a'.repeat(64) }));
    reads++; assert.equal(url, `/dashboard/api/v1/work/${id}`); assert.equal(options.method, 'GET');
    assert.equal(options.headers['X-Switchboard-Session'], 'a'.repeat(64));
    assert.equal(options.credentials, 'omit'); assert.equal(options.redirect, 'error');
    return new Response(JSON.stringify(view));
  } });
  await session.connect(); assert.deepEqual(await session.work(id), view);
  await assert.rejects(session.work('../session'), { code: 'schema' }); assert.equal(reads, 1);
});
test('disconnect fences held work response and clears future access', async () => {
  let release; const held = new Promise(resolve => { release = resolve; });
  const session = createOperatorSession({ fetch: async url => {
    if (url.endsWith('/session')) return new Response(JSON.stringify({ session: 'a'.repeat(64) }));
    if (url.endsWith('/disconnect')) return new Response(null, { status: 204 });
    await held; return new Response(JSON.stringify(view));
  } });
  await session.connect(); const pending = session.work(id);
  const rejected = assert.rejects(pending, { code: 'cancelled' });
  await session.disconnect(); release(); await rejected;
  await assert.rejects(session.work(id), { code: 'disconnected' });
});
