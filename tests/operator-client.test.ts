import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHubClient } from '../extension/client.ts';
import type { OperatorAnnouncement } from '../extension/operator-binding.ts';
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const work = JSON.parse(readFileSync(new URL('./fixtures/operator-work.json', import.meta.url), 'utf8')).allNull;
const doc: OperatorAnnouncement = { schemaVersion: 1, agentId: id, sessionId: id, runtimeGeneration: '1', sessionGeneration: '1',
  branchId: null, activeRunId: null, registration: null, permissionRevision: '0', reportRevision: '1', capabilities: ['work.report.v1'],
  permissions: { notice: false, work: false, guidance: false, sessionRead: false, label: false, interrupt: false, content: false, workAssign: false, history: false }, work };
const receipt = { ...doc, registration: { epoch: id, generation: '1' }, bindingId: id, workRevision: '0' } as Record<string, unknown>;
delete receipt.permissions; delete receipt.work;
test('native announcement uses bearer namespace, validates binding and never retries', async () => {
  let calls = 0;
  const client = createHubClient({ baseUrl: 'http://127.0.0.1:7420', token: 'synthetic', fetch: async (url, options) => {
    calls++; assert.equal(url, 'http://127.0.0.1:7420/v1/operator/announce');
    assert.equal(options?.method, 'POST'); assert.equal(options?.headers?.authorization, 'Bearer synthetic');
    assert.equal(options?.headers?.['X-Switchboard-Session'], undefined);
    return new Response(JSON.stringify(receipt), { status: 200 });
  } });
  assert.deepEqual(await client.announce(doc), { status: 'ok', binding: receipt });
  assert.equal(calls, 1);
});
test('stale receipts and lost responses are unknown, never implicit legacy success', async () => {
  for (const response of [() => new Response(JSON.stringify({ ...receipt, sessionGeneration: '2' })), () => { throw new Error('lost'); }]) {
    let calls = 0;
    const client = createHubClient({ baseUrl: 'http://localhost:7420', token: 'synthetic', fetch: async () => { calls++; return response(); } });
    assert.equal((await client.announce(doc)).status, 'outcome_unknown'); assert.equal(calls, 1);
  }
});
test('unsupported endpoints and explicit rejection remain distinct; no echoed diagnostics', async () => {
  for (const status of [401, 404, 405, 409, 503]) {
    const client = createHubClient({ baseUrl: 'http://localhost:7420', token: 'synthetic', fetch: async () =>
      new Response(JSON.stringify({ error: { code: 'private', message: 'do not echo synthetic credential' } }), { status }) });
    const result = await client.announce(doc);
    assert.equal(result.status, [404, 405].includes(status) ? 'unsupported' : 'rejected');
    assert.equal(JSON.stringify(result).includes('credential'), false);
    assert.equal(client.isUnauthorized(), status === 401);
  }
});
test('binding validation uses the dispatched snapshot, not later caller mutation', async () => {
  const input = structuredClone(doc);
  const client = createHubClient({ baseUrl: 'http://localhost:7420', token: 'synthetic', fetch: async () => {
    input.sessionGeneration = '99';
    return new Response(JSON.stringify(receipt));
  } });
  assert.equal((await client.announce(input)).status, 'ok');
});

test('known native conflicts are classified without reflecting remote text', async () => {
  for (const code of ['epoch_reset', 'stale_generation', 'conflict', 'capacity']) {
    const client = createHubClient({ baseUrl: 'http://localhost:7420', token: 'synthetic', fetch: async () =>
      new Response(JSON.stringify({ error: { code, message: 'private diagnostic' } }), { status: 409 }) });
    assert.deepEqual(await client.announce(doc), { status: 'rejected', reason: code });
  }
});

test('invalid announcements and cancelled calls do not dispatch', async () => {
  let calls = 0;
  const client = createHubClient({ baseUrl: 'http://localhost:7420', token: 'synthetic', fetch: async () => { calls++; throw new Error(); } });
  assert.equal((await client.announce({ ...doc, runtimeGeneration: '-1' })).status, 'not_sent');
  const abort = new AbortController(); abort.abort();
  assert.equal((await client.announce(doc, abort.signal)).status, 'not_sent');
  assert.equal(calls, 0);
});
