import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createAnnouncer } from '../extension/operator-announcer.ts';
import type { OperatorAnnouncement, OperatorBinding } from '../extension/operator-binding.ts';
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const work = JSON.parse(readFileSync(new URL('./fixtures/operator-work.json', import.meta.url), 'utf8')).allNull;
const base = () => ({ schemaVersion: 1 as const, agentId: id, sessionId: id, runtimeGeneration: '1', sessionGeneration: '1',
  branchId: null, activeRunId: null, permissionRevision: '0', capabilities: ['work.report.v1' as const],
  permissions: { notice: false, work: false, guidance: false, sessionRead: false, label: false, interrupt: false, content: false, workAssign: false, history: false }, work });
const binding = (doc: OperatorAnnouncement): OperatorBinding => {
  const { permissions, work, ...context } = doc;
  return { ...context, registration: { epoch: id, generation: '1' }, bindingId: id, workRevision: '1' };
};
test('announcer is timer-free, single-flight and probes unchanged metadata on a bounded cadence', async () => {
  let calls = 0, now = 0; let release!: () => void;
  const held = new Promise<void>(r => { release = r; });
  const a = createAnnouncer({ now: () => now, snapshot: base, send: async doc => {
    calls++; if (calls === 1) await held;
    return { status: 'ok', binding: binding(doc) };
  } });
  assert.equal(calls, 0); const pending = a.tick(); assert.equal(a.tick(), pending); release(); await pending;
  await a.tick(); // Echo newly assigned registration once.
  const n = calls; await a.tick(); assert.equal(calls, n);
  now = 30001; await a.tick(); assert.equal(calls, n + 1);
});
test('work updates advance report revision without inventing unknown fields', async () => {
  let snapshot = base(); const sent: OperatorAnnouncement[] = [];
  const a = createAnnouncer({ snapshot: () => snapshot, send: async doc => {
    sent.push(doc); return { status: 'ok', binding: binding(doc) };
  } });
  await a.tick(); snapshot = { ...snapshot, work: { ...work, currentStep: 'Reviewing' } }; await a.tick();
  assert.equal(sent.at(-1)?.work.objective, null);
  assert.ok(BigInt(sent[1].reportRevision) > BigInt(sent[0].reportRevision));
});
test('stop fences an uncooperative reply and prevents any later announcement', async () => {
  let finish!: (v: { status: 'ok'; binding: OperatorBinding }) => void; let published = 0;
  const a = createAnnouncer({ snapshot: base, onBinding: () => { published++; }, send: doc =>
    new Promise(r => { finish = r; }) });
  const pending = a.tick(); a.stop();
  finish({ status: 'ok', binding: binding({ ...base(), registration: null, reportRevision: '1' }) });
  await pending; await a.tick(); assert.equal(published, 0);
});
test('late binding cannot publish after the local session context changes', async () => {
  let snapshot = base(), published: OperatorBinding | null = null;
  let finish!: () => void;
  const a = createAnnouncer({ snapshot: () => snapshot, onBinding: v => { published = v; }, send: doc =>
    new Promise(resolve => { finish = () => resolve({ status: 'ok', binding: binding(doc) }); }) });
  const pending = a.tick(); snapshot = { ...snapshot, sessionGeneration: '2' }; finish(); await pending;
  assert.equal(published, null);
});

test('unsupported and transient failures back off without latching across hub upgrades', async () => {
  let now = 0, calls = 0;
  const a = createAnnouncer({ now: () => now, snapshot: base, send: async () => { calls++; return { status: 'unsupported' }; } });
  await a.tick(); now = 5000; await a.tick(); assert.equal(calls, 1);
  now = 30000; await a.tick(); assert.equal(calls, 2);
});
