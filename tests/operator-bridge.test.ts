import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import type { ExtensionAPI, ExtensionContext } from '@earendil-works/pi-coding-agent';
import type { HubClient } from '../extension/client.ts';
import type { OperationDescriptor, OperationKind, OperationReport } from '../extension/operator-operations.ts';
import { createOperatorBridge, bridgeCapabilities, type OperatorContext } from '../extension/operator-bridge.ts';
import { emptyWork } from '../extension/runtime.ts';
const agent = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', op = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const run = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', bind = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const flush = async () => { for (let n = 0; n < 80; n++) await Promise.resolve(); };
function fixture(kind: OperationKind, body = 'hello') {
  let mono = 0;
  const reports: OperationReport[] = [], sdkCalls: unknown[] = [], labels: string[] = [], workReports: unknown[] = [];
  const entries = new Map<string, any>();
  const ctx = { isIdle: () => false, sessionManager: { getSessionId: () => agent, getLeafId: () => 'leaf', getEntry: (id: string) => entries.get(id) },
    abort: () => { sdkCalls.push('abort'); }, ui: { notify() {} } } as unknown as ExtensionContext;
  const current: OperatorContext = { ctx, active: true, sessionGeneration: '1', branchId: null, runId: run, workId: null,
    permissions: { notice: true, work: true, guidance: true, sessionRead: true, label: true, interrupt: true, content: true, workAssign: true, history: false },
    binding: { schemaVersion: 1, agentId: agent, sessionId: agent, runtimeGeneration: '1', sessionGeneration: '1', branchId: null,
      activeRunId: run, registration: { epoch: agent, generation: '1' }, permissionRevision: '1', reportRevision: '1',
      capabilities: [...bridgeCapabilities], bindingId: bind, workRevision: '1' } };
  const descriptor: OperationDescriptor = { schemaVersion: 1, operationId: op, kind, agentId: agent, sessionId: agent,
    bindingId: bind, runtimeGeneration: '1', sessionGeneration: '1', branchId: null, runId: kind === 'interrupt' ? run : null,
    workId: null, deadline: '30000', content: { encoding: 'handle', contentId: op, bytes: String(Buffer.byteLength(body)) } };
  const client = { operatorRequests: async () => ({ status: 'ok', requests: [descriptor] }),
    operatorContent: async () => ({ status: 'ok', body }),
    operatorReport: async (report: OperationReport) => { reports.push(report); return { status: 'ok', state: report.kind === 'receipt'
      ? report.status === 'rejected' ? 'rejected' : kind === 'notice' ? 'received' : kind === 'sessionRead' ? 'assembling' : 'accepted'
      : report.kind === 'fragment' ? 'completed' : report.status }; },
    operatorActivity: async () => ({ status: 'ok', accepted: 0 }),
  } as unknown as HubClient;
  const pi = { sendUserMessage: (text: string, options: unknown) => { sdkCalls.push({ text, options }); } } as unknown as ExtensionAPI;
  const bridge = createOperatorBridge({ client, pi, current: () => current, now: () => mono, wall: () => mono, uuid: () => op,
    setLabel: text => { labels.push(text); return text; }, assignWork: work => { workReports.push(work); return true; } });
  return { bridge, current, descriptor, client, pi, entries, reports, sdkCalls, labels, workReports, time: (n: number) => { mono = n; } };
}

test('push wakes coalesce during a request and heartbeat-only ticks do not fetch requests', async () => {
  const f = fixture('notice'); let calls = 0, release!: () => void;
  f.client.operatorRequests = async () => { calls++; if (calls === 1) await new Promise<void>(resolve => { release = resolve; }); return { status: 'ok', requests: [] }; };
  try {
    await f.bridge.tick(false); assert.equal(calls, 0);
    const first = f.bridge.wake(); await flush();
    for (let n = 0; n < 100; n++) void f.bridge.wake();
    assert.equal(calls, 1); release(); await first; await flush();
    assert.equal(calls, 2);
    f.bridge.stop(); await f.bridge.wake(); assert.equal(calls, 2);
  } finally { f.bridge.stop(); }
});

test('work is attempted once; synchronous matching input reports follow the attempt', async () => {
  const f = fixture('work');
  f.pi.sendUserMessage = ((text: string) => { f.sdkCalls.push(text); f.bridge.message({ role: 'user', content: text, timestamp: 0 }); }) as any;
  await f.bridge.tick(); await flush(); await f.bridge.tick(); await flush();
  assert.equal(f.sdkCalls.length, 1);
  assert.deepEqual(f.reports.map(r => r.kind === 'fragment' ? 'fragment' : r.status), ['received', 'attempted', 'observed']);
  f.bridge.stop();
});
test('changed work or revoked permission during content fetch cannot invoke SDK', async () => {
  for (const revoke of [() => { f.current.workId = run; }, () => { f.current.permissions.work = false; }]) {
    var f = fixture('work');
    f.client.operatorContent = async () => { revoke(); return { status: 'ok', body: 'hello' }; };
    await f.bridge.tick(); await flush(); assert.equal(f.sdkCalls.length, 0);
    assert.equal((f.reports.at(-1) as any).status, 'rejected'); f.bridge.stop();
  }
});
test('unknown receipt never invokes or replays an effect', async () => {
  const f = fixture('work');
  f.client.operatorReport = async () => ({ status: 'outcome_unknown', reason: 'lost' });
  await f.bridge.tick(); await f.bridge.tick(); assert.equal(f.sdkCalls.length, 0); f.bridge.stop();
});
test('guidance requires activity; interrupt pins the exact active run', async () => {
  const guide = fixture('guidance'); guide.current.ctx.isIdle = () => true;
  await guide.bridge.tick(); assert.equal(guide.sdkCalls.length, 0); guide.bridge.stop();
  const interrupt = fixture('interrupt'); interrupt.current.runId = op;
  await interrupt.bridge.tick(); assert.equal(interrupt.sdkCalls.length, 0); interrupt.bridge.stop();
});
test('label and structured assignment use typed local handlers, not prompts', async () => {
  const f = fixture('label', 'Review'); await f.bridge.tick(); await flush();
  assert.deepEqual(f.labels, ['Review']); assert.equal(f.sdkCalls.length, 0);
  assert.equal((f.reports.at(-1) as any).status, 'labelled'); f.bridge.stop();
  const work = { ...emptyWork(), workId: op, objective: 'New objective' };
  const a = fixture('workAssign', JSON.stringify(work)); await a.bridge.tick(); await flush();
  assert.deepEqual(a.workReports, [work]); assert.equal(a.sdkCalls.length, 0);
  assert.equal((a.reports.at(-1) as any).status, 'work_assigned'); a.bridge.stop();
});
test('notice receipt, reservation and observation remain separate and passive', async () => {
  const f = fixture('notice', 'x'.repeat(16384)); await f.bridge.tick(); await flush();
  assert.deepEqual(f.reports.map(r => (r as any).status), ['received']); assert.equal(f.sdkCalls.length, 0);
  const text = f.bridge.takeNotices(); assert.ok(text.includes('x'.repeat(16384))); await flush();
  assert.equal((f.reports.at(-1) as any).status, 'context_reserved');
  f.bridge.message({ role: 'custom', customType: 'agent-bus-mail', content: text, display: true, timestamp: 0 } as any);
  await flush(); assert.equal((f.reports.at(-1) as any).status, 'observed'); f.bridge.stop();
});
test('interrupt reports request before matching synchronous settlement, never kill', async () => {
  const f = fixture('interrupt', '');
  f.current.ctx.abort = () => { f.sdkCalls.push('abort'); f.bridge.settled(run); };
  await f.bridge.tick(); await flush();
  assert.deepEqual(f.sdkCalls, ['abort']);
  assert.deepEqual(f.reports.map(r => (r as any).status), ['received', 'abort_requested', 'settled']); f.bridge.stop();
});
test('session content requires enrollment and exports only bounded visible projection', async () => {
  const denied = fixture('sessionRead', '{"leafId":null,"limit":"64"}'); denied.current.permissions.content = false;
  await denied.bridge.tick(); assert.equal((denied.reports.at(-1) as any).status, 'rejected'); denied.bridge.stop();
  const f = fixture('sessionRead', '{"leafId":null,"limit":"64"}');
  f.entries.set('leaf', { type: 'message', id: 'leaf', parentId: 'tool', message: { role: 'assistant', content: [
    { type: 'thinking', thinking: 'HIDDEN_SENTINEL' }, { type: 'text', text: 'Visible answer' }, { type: 'toolCall', arguments: { secret: 'ARGS_SENTINEL' } }] } });
  f.entries.set('tool', { type: 'message', id: 'tool', parentId: 'user', message: { role: 'toolResult', toolName: 'bash', content: [{ type: 'text', text: 'RAW_SENTINEL' }], details: { secret: 'DETAIL_SENTINEL' }, isError: false } });
  f.entries.set('user', { type: 'message', id: 'user', parentId: null, message: { role: 'user', content: 'User text' } });
  await f.bridge.tick(); await flush();
  const fragments = f.reports.filter((r): r is Extract<OperationReport, { kind: 'fragment' }> => r.kind === 'fragment');
  const bytes = Buffer.concat(fragments.map(r => Buffer.from(r.data, 'base64')));
  const page = JSON.parse(bytes.toString());
  assert.equal(fragments.at(-1)?.digest, createHash('sha256').update(bytes).digest('hex'));
  assert.ok(page.records.some((r: any) => r.text === 'Visible answer'));
  assert.equal(/SENTINEL/.test(bytes.toString()), false); assert.ok(bytes.length <= 524288); f.bridge.stop();
});
test('stopped bridge has no producers or late effects', async () => {
  const f = fixture('work'); f.bridge.stop(); await f.bridge.tick(); assert.equal(f.reports.length, 0); assert.equal(f.sdkCalls.length, 0);
});
