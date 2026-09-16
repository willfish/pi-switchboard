import test from 'node:test';
import assert from 'node:assert/strict';
import { createAgentBusExtension } from '../extension/index.ts';
import { emptyWork } from '../extension/runtime.ts';
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
    await assert.rejects(tool.execute('call', { ...work, secret: 'forbidden' }, undefined), /invalid/);
    assert.equal(sdk.entries.length, 1);
  } finally { await runtime.sessionShutdown(); }
});
