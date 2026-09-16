import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodeWorkView } from '../hub/priv/dashboard/operator-work.js';
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const fixture = JSON.parse(readFileSync(new URL('./fixtures/operator-work.json', import.meta.url), 'utf8'));
const encode = x => new TextEncoder().encode(JSON.stringify(x));
const view = () => ({ binding: { schemaVersion: 1, agentId: id, sessionId: id, runtimeGeneration: '1', sessionGeneration: '1',
  branchId: null, activeRunId: null, registration: { epoch: id, generation: '1' }, permissionRevision: '0', reportRevision: '1',
  capabilities: ['work.report.v1'], bindingId: id, workRevision: '1' }, work: fixture.allNull,
  permissions: { notice: false, work: false, guidance: false, sessionRead: false, label: false, interrupt: false, content: false, workAssign: false, history: false } });
test('work view preserves complete null metadata and exact runtime identity', () => {
  assert.deepEqual(decodeWorkView(encode(view()), id), view());
  assert.throws(() => decodeWorkView(encode(view()), 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'));
});
for (const [name, change] of [
  ['extra work data', v => { v.work = { ...v.work, password: 'no' }; }],
  ['missing step', v => { v.work = { ...v.work }; delete v.work.currentStep; }],
  ['numeric counter', v => { v.binding.reportRevision = 1; }],
  ['unbounded counter', v => { v.binding.runtimeGeneration = '18446744073709551616'; }],
  ['invented permission', v => { v.permissions.admin = true; }],
  ['duplicate capability', v => { v.binding.capabilities.push('work.report.v1'); }],
  ['unknown capability', v => { v.binding.capabilities = ['shell.execute']; }],
  ['path handle', v => { v.binding.branchId = '/tmp/session.json'; }],
  ['invalid phase', v => { v.work = { ...v.work, phase: 'done' }; }],
  ['oversized text', v => { v.work = { ...v.work, objective: 'x'.repeat(2049) }; }],
]) test(`rejects ${name}`, () => { const v = view(); change(v); assert.throws(() => decodeWorkView(encode(v), id)); });
test('work response has an independent raw-byte cap and duplicate-key rejection', () => {
  assert.throws(() => decodeWorkView(new Uint8Array(65537), id));
  const text = JSON.stringify(view()).replace('"objective":null', '"objective":null,"objectiv\\u0065":null');
  assert.throws(() => decodeWorkView(new TextEncoder().encode(text), id));
});
