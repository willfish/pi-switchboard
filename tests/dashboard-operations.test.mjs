import test from 'node:test';
import assert from 'node:assert/strict';
import { createOperatorSession } from '../hub/priv/dashboard/operator-session.js';
import { canAct, makeOperation, decodeOperation, newOperationId } from '../hub/priv/dashboard/operator-actions.js';
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const other = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const view = { binding: { agentId: id, sessionId: id, bindingId: other, runtimeGeneration: '1', sessionGeneration: '2', branchId: null,
  activeRunId: other, capabilities: ['notice.receive.v1', 'session.current.read.v1', 'run.interrupt.active.v1'] },
  work: { workId: null }, permissions: { notice: true, sessionRead: true, content: false, interrupt: true } };
const status = (operationId = id) => ({ schemaVersion: 1, operationId, kind: 'notice', agentId: id, sessionId: id, bindingId: other,
  runtimeGeneration: '1', sessionGeneration: '2', branchId: null, runId: null, workId: null, state: 'queued',
  createdAt: '1000', deadline: '25000', expiresAt: '25000', unsupportedWithdrawal: false, unsupported: ['notice_not_executed'], page: null });
const encode = v => new TextEncoder().encode(JSON.stringify(v));
test('intent pins exact context and does not derive permission from unrelated flags', () => {
  assert.equal(canAct(view, 'notice'), true); assert.equal(canAct(view, 'sessionRead'), false);
  const op = makeOperation(view, 'interrupt', { reason: null }, id);
  assert.equal(op.runId, other); assert.equal(op.workId, null); assert.equal(op.bindingId, other);
  assert.equal(canAct({ ...view, binding: { ...view.binding, activeRunId: null } }, 'interrupt'), false);
  assert.throws(() => makeOperation(view, 'label', { label: 'no' }));
});
test('operation UUID creation uses getRandomValues, available on tailnet HTTP', () => {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'crypto');
  try {
    Object.defineProperty(globalThis, 'crypto', { configurable: true, value: { getRandomValues: bytes => { bytes.fill(7); return bytes; } } });
    assert.match(newOperationId(), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  } finally { Object.defineProperty(globalThis, 'crypto', original); }
});
test('status rejects changed identity, unknown fields and hidden/raw projection data', () => {
  assert.deepEqual(decodeOperation(encode(status()), id), status());
  assert.throws(() => decodeOperation(encode(status()), other));
  assert.throws(() => decodeOperation(encode({ ...status(), secret: 'no' }), id));
  const p = { schemaVersion: 1, sessionId: id, leafId: 'leaf', nextLeafId: null, records: [{ entryId: 'leaf', role: 'assistant', text: 'visible' }], omitted: 0, truncated: false };
  assert.ok(decodeOperation(encode({ ...status(), kind: 'sessionRead', state: 'completed', page: p }), id));
  p.records[0].thinking = 'hidden';
  assert.throws(() => decodeOperation(encode({ ...status(), kind: 'sessionRead', state: 'completed', page: p }), id));
});
test('uncertain create is sent once and reconciled only through GET', async () => {
  let posts = 0, reads = 0;
  const session = createOperatorSession({ fetch: async (url, options) => {
    assert.equal(options.credentials, 'omit'); assert.equal(options.redirect, 'error'); assert.equal(options.mode, 'same-origin');
    if (url.endsWith('/session')) return new Response(JSON.stringify({ session: 'a'.repeat(64) }));
    assert.equal(options.headers['X-Switchboard-Session'], 'a'.repeat(64)); assert.equal(options.headers.Authorization, undefined);
    if (options.method === 'POST') { posts++; throw new Error('lost after dispatch'); }
    reads++; return new Response(JSON.stringify(status()));
  } });
  await session.connect();
  await assert.rejects(session.createOperation(makeOperation(view, 'notice', { text: 'hello' }, id)), { code: 'outcome_unknown' });
  assert.equal(posts, 1); assert.equal((await session.operationStatus(id)).state, 'queued'); assert.equal(reads, 1); assert.equal(posts, 1);
});
test('operation ownership denial does not renew an otherwise valid browser session', async () => {
  let bootstraps = 0;
  const session = createOperatorSession({ fetch: async url => {
    if (url.endsWith('/session')) { bootstraps++; return new Response(JSON.stringify({ session: 'a'.repeat(64) })); }
    return new Response(JSON.stringify({ error: { code: 'forbidden', message: 'not this operator session' } }), { status: 403 });
  } });
  await session.connect(); await assert.rejects(session.operationStatus(id), { code: 'forbidden' });
  assert.equal(bootstraps, 1);
});

test('disconnect aborts and fences late mutation responses without replay', async () => {
  let release; const held = new Promise(r => { release = r; }); let writes = 0;
  const session = createOperatorSession({ fetch: async url => {
    if (url.endsWith('/session')) return new Response(JSON.stringify({ session: 'a'.repeat(64) }));
    if (url.endsWith('/disconnect')) return new Response(null, { status: 204 });
    writes++; await held; return new Response(JSON.stringify(status()));
  } });
  await session.connect(); const pending = session.createOperation(makeOperation(view, 'notice', { text: 'hello' }, id));
  const unknown = assert.rejects(pending, { code: 'outcome_unknown' });
  await session.disconnect(); release(); await unknown; assert.equal(writes, 1);
});
