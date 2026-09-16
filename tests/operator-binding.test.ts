import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { isAnnouncement, isBindingFor, encodeAnnouncement, type OperatorAnnouncement } from '../extension/operator-binding.ts';
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const work = JSON.parse(readFileSync(new URL('./fixtures/operator-work.json', import.meta.url), 'utf8')).allNull;
const announcement = (): OperatorAnnouncement => ({ schemaVersion: 1, agentId: id, sessionId: id, runtimeGeneration: '1', sessionGeneration: '1',
  branchId: null, activeRunId: null, registration: null, permissionRevision: '0', reportRevision: '1', capabilities: ['work.report.v1'],
  permissions: { notice: false, work: false, guidance: false, sessionRead: false, label: false, interrupt: false, content: false, workAssign: false, history: false }, work });
const receipt = () => ({ schemaVersion: 1, agentId: id, sessionId: id, runtimeGeneration: '1', sessionGeneration: '1',
  branchId: null, activeRunId: null, registration: { epoch: id, generation: '1' }, permissionRevision: '0', reportRevision: '1',
  capabilities: ['work.report.v1'], bindingId: id, workRevision: '0' });
test('accepts complete metadata-only announcement and context-bound receipt', () => {
  assert.equal(isAnnouncement(announcement()), true);
  assert.equal(isBindingFor(receipt(), announcement()), true);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(encodeAnnouncement(announcement()))), announcement());
});
test('rejects unknown fields, duplicate capabilities, unsafe generations and filesystem handles', () => {
  for (const patch of [{ secret: 'no' }, { runtimeGeneration: 1 }, { sessionGeneration: '01' },
    { runtimeGeneration: '18446744073709551616' }, { branchId: '/tmp/session.jsonl' },
    { capabilities: ['work.report.v1', 'work.report.v1'] }, { capabilities: ['shell.execute.v1'] },
    { permissions: { ...announcement().permissions, admin: true } }, { registration: { epoch: id, generation: '0x1' } }]) {
    assert.equal(isAnnouncement({ ...announcement(), ...patch }), false);
  }
});
test('receipt cannot change selected context or grant unadvertised capabilities', () => {
  for (const patch of [{ runtimeGeneration: '2' }, { sessionGeneration: '2' }, { permissionRevision: '1' }, { reportRevision: '2' },
    { branchId: 'new-leaf' }, { agentId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' },
    { capabilities: ['label.set.v1'] }, { bindingId: null }, { hidden: true }]) {
    assert.equal(isBindingFor({ ...receipt(), ...patch }, announcement()), false);
  }
  const bound = { ...announcement(), registration: { epoch: id, generation: '3' } };
  assert.equal(isBindingFor(receipt(), bound), false);
});
test('announcement cap includes the complete envelope, not just work fields', () => {
  const a = announcement();
  assert.throws(() => encodeAnnouncement({ ...a, work: { ...work, objective: 'x'.repeat(32768) } }));
});
