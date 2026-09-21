import test from 'node:test';
import assert from 'node:assert/strict';
import { createAgentBusExtension } from '../extension/index.ts';
import { emptyWork } from '../extension/runtime.ts';
import { stableWorkUuid } from '../extension/operator-protocol.ts';
import { host, context, Clock, dormantSubscribe, response, agentA, flush } from './client-test-helpers.ts';
test('work tool records explicit metadata without granting permissions or claiming delivery', async () => {
  const sdk = host(), clock = new Clock();
  const runtime = createAgentBusExtension({ pi: sdk.pi, uuid: () => agentA, env: { PI_AGENT_BUS_TOKEN: 'synthetic' },
    timers: clock, now: () => clock.time, subscribe: dormantSubscribe, fetch: async () => response() });
  runtime.sessionStart({}, context()); await flush();
  try {
    const tool = sdk.tools.get('report_work'); assert.ok(tool);
    const work = { ...emptyWork(), workId: agentA, currentStep: 'Inspecting', nextStep: 'Test', blocker: { kind: 'decision', reason: 'Need a choice' } };
    const result = await tool.execute('call', work, undefined);
    assert.match(result.content[0].text, /locally/); assert.doesNotMatch(result.content[0].text, /delivered|executed/);
    assert.deepEqual(runtime.currentWork(), work); assert.equal(runtime.acceptsControl(), false);
    assert.equal(sdk.injected.length, 0); assert.equal(sdk.entries.length, 1);
    const cancelled = new AbortController(); cancelled.abort();
    await assert.rejects(tool.execute('call', work, cancelled.signal), /cancelled/);
    const extra = await tool.execute('call', { ...work, secret: 'forbidden' }, undefined);
    assert.match(extra.content[0].text, /locally/);
    assert.equal('secret' in runtime.currentWork(), false);
    assert.deepEqual(runtime.currentWork(), work);
    assert.equal(JSON.stringify(sdk.entries).includes('forbidden'), false);
  } finally { await runtime.sessionShutdown(); }
});

test('work tool maps slug ids and labels folder-only sessions from the objective', async () => {
  const sdk = host(), clock = new Clock();
  const runtime = createAgentBusExtension({ pi: sdk.pi, uuid: () => agentA, cwd: () => '/tmp/work',
    env: { PI_AGENT_BUS_TOKEN: 'synthetic' }, timers: clock, now: () => clock.time,
    subscribe: dormantSubscribe, fetch: async () => response() });
  runtime.sessionStart({}, context()); await flush();
  try {
    const tool = sdk.tools.get('report_work'); assert.ok(tool);
    const result = await tool.execute('call', { workId: 'pr-1453-review', objective: 'Review PR 1453' }, undefined);
    const stored = runtime.currentWork();
    assert.equal(stored.workId, stableWorkUuid('pr-1453-review'));
    assert.equal(stored.objective, 'Review PR 1453');
    assert.equal(runtime.label(), 'Review PR 1453');
    assert.equal(result.details.work.workId, stored.workId);
    assert.deepEqual(sdk.entries.find(entry => entry.type === 'agent-bus-label'), { type: 'agent-bus-label', data: { label: 'Review PR 1453' } });
  } finally { await runtime.sessionShutdown(); }
});

test('work tool does not replace an explicit session name with the objective', async () => {
  const sdk = host(), clock = new Clock(); sdk.setName('Named session');
  const runtime = createAgentBusExtension({ pi: sdk.pi, uuid: () => agentA, cwd: () => '/tmp/work',
    env: { PI_AGENT_BUS_TOKEN: 'synthetic' }, timers: clock, now: () => clock.time,
    subscribe: dormantSubscribe, fetch: async () => response() });
  runtime.sessionStart({}, context()); await flush();
  try {
    const tool = sdk.tools.get('report_work'); assert.ok(tool);
    await tool.execute('call', { workId: 'pr-1453-review', objective: 'Review PR 1453' }, undefined);
    assert.equal(runtime.label(), 'Named session');
    assert.equal(sdk.entries.some(entry => entry.type === 'agent-bus-label'), false);
  } finally { await runtime.sessionShutdown(); }
});
