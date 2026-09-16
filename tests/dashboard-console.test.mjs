import test from 'node:test';
import assert from 'node:assert/strict';
import { createCommunications, createInspector, eventTime, historyTime } from '../hub/priv/dashboard/console-view.js';
test('event timestamps display safely without uint64 rounding', () => {
  assert.equal(eventTime('0'), '1970-01-01 00:00:00 UTC');
  assert.equal(eventTime(null), 'Unknown');
  assert.equal(eventTime('18446744073709551615'), 'Date unavailable');
});
test('inspector pins runtime and session, never retargeting by shared saved session', () => {
  let state;
  const view = createInspector(s => { state = s; });
  const a = { agentId: 'a', sessionId: 'shared', label: 'First' };
  const b = { agentId: 'b', sessionId: 'shared', label: 'Second' };
  view.select(a); view.update([b], true);
  assert.equal(state.agent.agentId, 'a'); assert.equal(state.availability, 'missing');
  view.update([{ ...a, sessionId: 'replacement' }], true);
  assert.equal(state.target.sessionId, 'shared'); assert.equal(state.contextChanged, true);
  view.update([], false); assert.equal(state.availability, 'unknown');
  view.clear(); assert.equal(state, null);
});
test('inspector fences old work reads and coalesces selection changes', async () => {
  let state, release; const calls = [];
  const held = new Promise(resolve => { release = resolve; });
  const view = createInspector(s => { state = s; }, async id => {
    calls.push(id); if (id === 'a') await held;
    return { binding: { agentId: id, sessionId: 's' }, work: { objective: id } };
  });
  view.select({ agentId: 'a', sessionId: 's' });
  view.select({ agentId: 'b', sessionId: 's' }); view.select({ agentId: 'c', sessionId: 's' });
  release();
  for (let i = 0; i < 30; i++) await Promise.resolve();
  assert.deepEqual(calls, ['a', 'c']); assert.equal(state.workView.work.objective, 'c');
  view.clear(); assert.equal(state, null);
});
test('history search controls use the same UTC clock as displayed events', () => {
  assert.equal(historyTime('2026-09-15T12:30'), String(Date.UTC(2026, 8, 15, 12, 30) / 1000));
  assert.equal(historyTime('not-a-date'), null);
});
const epoch = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const page = (events = []) => ({ epoch, fromSequence: '0', toSequence: String(events.length), retainedFrom: '1', coverage: 'live', caughtUp: true, nextCursor: null, events });
test('communications loads only when selected and connected, pauses by default', async () => {
  let calls = 0; const states = [];
  const view = createCommunications({ operator: { events: async () => { calls++; return page([{ kind: 'mail_accepted' }]); } }, render: s => states.push(s) });
  view.setConnected(true); assert.equal(calls, 0);
  await view.select(true); assert.equal(calls, 1); assert.equal(states.at(-1).events.length, 1);
  assert.equal(states.at(-1).following, false); view.setConnected(false);
  assert.equal(states.at(-1).events.length, 0);
});
test('disconnect clears and fences a held page, without replay', async () => {
  let release; const held = new Promise(resolve => { release = resolve; }); const states = [];
  const view = createCommunications({ operator: { events: () => held }, render: s => states.push(s) });
  view.setConnected(true); const pending = view.select(true); view.setConnected(false);
  release(page([{ kind: 'mail_accepted' }])); await pending;
  assert.equal(states.at(-1).events.length, 0); assert.equal(states.at(-1).connected, false);
});
test('history failure clears records and requires an explicit retained-history read', async () => {
  let calls = 0; const states = [];
  const view = createCommunications({ operator: { events: async () => {
    if (++calls === 1) return page([{ kind: 'mail_accepted' }]);
    throw Object.assign(new Error(), { code: 'history' });
  } }, render: s => states.push(s) });
  view.setConnected(true); await view.select(true); await view.load();
  assert.equal(calls, 2); assert.equal(states.at(-1).events.length, 0);
  assert.match(states.at(-1).error, /history/i); assert.equal(states.at(-1).following, false);
});
