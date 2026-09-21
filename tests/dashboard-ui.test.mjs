import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createController, counts, selectAgents, displayIds, mountDashboard, agentState } from '../hub/priv/dashboard/dashboard.js';
import { DiscoveryError } from '../hub/priv/dashboard/protocol.js';

const id = (n) => `${n.toString(16).padStart(8, '0')}-0000-0000-0000-000000000000`;
const nonce = (n = 1) => n.toString(16).padStart(64, '0');
const agent = (n, patch = {}) => ({ agentId: id(n), sessionId: id(999), host: 'synthetic-host', cwd: '/synthetic',
  sessionName: 'shared session', label: `Runtime ${n}`, model: null, status: 'idle', pid: n + 1,
  updatedAt: 1770000000, receiving: false, acceptsControl: false, ...patch });
const snapshot = (agents = []) => ({ epoch: id(9000), snapshotId: id(9001), revision: '1',
  capturedAt: 1770000000, total: agents.length, agents });
const pageDoc = (agents = []) => ({ ...snapshot(agents), page: 0, nextCursor: null });
const settle = async () => { for (let n = 0; n < 40; n++) await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
function harness() {
  const pending = [], states = [], timers = new Map(); let serial = 0;
  const operator = {
    connect() { const d = deferred(); pending.push({ kind: 'connect', signal: { aborted: false }, ...d }); return d.promise; },
    presence() { const d = deferred(); pending.push({ kind: 'presence', signal: { aborted: false }, ...d }); return d.promise; },
    disconnect() { const d = deferred(); pending.push({ kind: 'disconnect', ...d }); queueMicrotask(() => d.resolve('complete')); return d.promise; },
  };
  const controller = createController({ operator, render: (s) => states.push(s), now: () => 123,
    setTimer: (fn, ms) => { timers.set(++serial, { fn, ms }); return serial; }, clearTimer: (key) => timers.delete(key) });
  return { controller, pending, states, timers, state: () => states.at(-1), tick() {
    const [key, t] = timers.entries().next().value; timers.delete(key); t.fn(); return t.ms;
  } };
}
async function succeed(h, value = snapshot()) {
  h.pending.filter((p) => p.kind === 'connect').at(-1).resolve();
  await settle();
  h.pending.filter((p) => p.kind === 'presence').at(-1).resolve(value);
  await settle();
}

test('push invalidations coalesce, retain changes during a read, and fall back after stream loss', async () => {
  const h = harness(); await succeed(h);
  for (let n = 0; n < 100; n++) h.controller.invalidate();
  assert.equal(h.timers.size, 1); assert.equal(h.tick(), 250);
  for (let n = 0; n < 100; n++) h.controller.invalidate();
  assert.equal(h.timers.size, 0);
  h.pending.filter(p => p.kind === 'presence').at(-1).resolve(snapshot()); await settle();
  assert.equal(h.tick(), 250);
  h.pending.filter(p => p.kind === 'presence').at(-1).resolve(snapshot()); await settle();
  assert.equal([...h.timers.values()][0].ms, 60000);
  h.controller.setPush(false); assert.equal([...h.timers.values()][0].ms, 15000);
  h.controller.setAuto(false); h.controller.invalidate(); assert.equal(h.timers.size, 0);
  h.controller.disconnect(); assert.equal(h.timers.size, 0);
});

test('single flight, historical refresh, failure clearing, backoff, hidden pause and return', async () => {
  const h = harness();
  assert.equal(h.state().snapshot, null); assert.equal(h.state().loading, true); assert.equal(h.state().connected, true);
  void h.controller.refresh(); assert.equal(h.pending.filter((p) => p.kind === 'connect').length, 1);
  const original = snapshot([agent(1)]); await succeed(h, original);
  assert.equal(h.state().snapshot, original); assert.equal(h.state().lastSuccess, 123);
  assert.equal(h.tick(), 15000); assert.equal(h.state().snapshot, original);
  h.pending.filter((p) => p.kind === 'presence').at(-1).reject(new DiscoveryError('reset')); await settle();
  assert.equal(h.state().snapshot, null); assert.equal(h.state().lastSuccess, 123); assert.match(h.state().error, /changed/);
  assert.equal(h.tick(), 30000); h.pending.filter((p) => p.kind === 'presence').at(-1).reject(new Error('REMOTE SECRET')); await settle();
  assert.equal(h.state().error.includes('REMOTE SECRET'), false); assert.equal([...h.timers.values()][0].ms, 60000);
  h.controller.setHidden(true); assert.equal(h.timers.size, 0);
  h.controller.setHidden(false); assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 4);
  h.pending.filter((p) => p.kind === 'presence').at(-1).resolve(snapshot()); await settle(); assert.equal([...h.timers.values()][0].ms, 15000);
  h.controller.setAuto(false); assert.equal(h.timers.size, 0);
  h.controller.setHidden(true); h.controller.setHidden(false); assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 4);
  h.controller.disconnect();
});

test('hidden pending reads settle without scheduling; return and auto changes never overlap', async () => {
  for (const reject of [false, true]) {
    for (const returnBeforeCompletion of [false, true]) {
      const h = harness();
      h.controller.setHidden(true);
      assert.equal(h.pending[0].signal.aborted, false);
      assert.equal(h.timers.size, 0);
      if (returnBeforeCompletion) h.controller.setHidden(false);
      void h.controller.refresh();
      assert.equal(h.pending.filter((p) => p.kind === 'connect').length, 1);
      if (reject) {
        h.pending[0].resolve(); await settle();
        h.pending[1].reject(new DiscoveryError('transport')); await settle();
      } else await succeed(h, snapshot([agent(1)]));
      assert.equal(h.state().loading, false);
      assert.equal(h.state().snapshot === null, reject);
      if (returnBeforeCompletion) {
        assert.equal(h.timers.size, 1);
        assert.equal([...h.timers.values()][0].ms, reject ? 30000 : 15000);
      } else {
        assert.equal(h.timers.size, 0);
        h.controller.setHidden(false);
        assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 2);
        void h.controller.refresh(); assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 2);
        h.pending.filter((p) => p.kind === 'presence').at(-1).resolve(snapshot()); await settle();
        assert.equal(h.timers.size, 1);
      }
      h.controller.disconnect();
    }
  }
  for (const reject of [false, true]) {
    const h = harness(); h.controller.setAuto(false);
    h.controller.setHidden(true); h.controller.setHidden(false);
    void h.controller.refresh(); assert.equal(h.pending.filter((p) => p.kind === 'connect').length, 1);
    if (reject) {
      h.pending[0].resolve(); await settle();
      h.pending[1].reject(new DiscoveryError('transport')); await settle();
    } else await succeed(h);
    assert.equal(h.timers.size, 0); assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 1);
    h.controller.setHidden(true); h.controller.setHidden(false); assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 1);
    void h.controller.refresh(); assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 2);
    h.controller.setAuto(true); assert.equal(h.timers.size, 0);
    void h.controller.refresh(); assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 2);
    h.pending.filter((p) => p.kind === 'presence').at(-1).resolve(snapshot()); await settle(); assert.equal(h.timers.size, 1);
    h.controller.disconnect();
  }
});

test('disconnect, reconnect and late results fence without leaking a nonce into state', async () => {
  const h = harness();
  h.controller.disconnect();
  h.pending[0].resolve(); await settle();
  assert.equal(h.state().snapshot, null); assert.equal(h.state().connected, false); assert.equal(h.timers.size, 0);
  h.controller.connect();
  h.pending.filter((p) => p.kind === 'connect').at(-1).resolve(); await settle();
  assert.equal(h.state().snapshot, null); assert.equal(h.state().loading, true);
  h.pending.filter((p) => p.kind === 'presence').at(-1).reject(new DiscoveryError('unauthorized')); await settle();
  assert.equal(h.state().connected, true); assert.equal(h.state().snapshot, null); assert.match(h.state().error, /can.t access/);
  h.controller.disconnect();
  h.pending.filter((p) => p.kind === 'presence').at(-1)?.reject?.(new DiscoveryError('unauthorized'));
  await settle();
  assert.equal(h.state().error, '');
  assert.equal(h.state().connected, false);
  assert.equal(JSON.stringify(h.states).includes('synthetic'), false);
  assert.equal(JSON.stringify(h.states).includes(nonce()), false);
});

test('stale disconnect completion cannot overwrite a newer invalidation', async () => {
  const pending = [], states = [];
  const operator = {
    connect() { const d = deferred(); pending.push({ kind: 'connect', ...d }); return d.promise; },
    presence() { const d = deferred(); pending.push({ kind: 'presence', ...d }); return d.promise; },
    disconnect() { const d = deferred(); pending.push({ kind: 'disconnect', ...d }); return d.promise; },
  };
  const controller = createController({ operator, render: (s) => states.push(s), now: () => 123,
    setTimer() { return 0; }, clearTimer() {} });
  const state = () => states.at(-1);
  controller.disconnect();
  assert.equal(pending.filter((p) => p.kind === 'disconnect').length, 1);
  assert.equal(state().invalidation, null);
  controller.connect();
  pending.filter((p) => p.kind === 'connect').at(-1).resolve(); await settle();
  pending.filter((p) => p.kind === 'presence').at(-1).resolve(snapshot()); await settle();
  controller.disconnect();
  assert.equal(pending.filter((p) => p.kind === 'disconnect').length, 2);
  assert.equal(state().invalidation, null);
  pending.filter((p) => p.kind === 'disconnect').at(-1).resolve('unknown'); await settle();
  assert.equal(state().invalidation, 'unknown');
  pending.filter((p) => p.kind === 'disconnect')[0].resolve('complete'); await settle();
  assert.equal(state().invalidation, 'unknown');
  assert.equal(state().connected, false);
  const late = [];
  const held = {
    connect() { const d = deferred(); late.push({ kind: 'connect', ...d }); return d.promise; },
    presence() { const d = deferred(); late.push({ kind: 'presence', ...d }); return d.promise; },
    disconnect() { const d = deferred(); late.push({ kind: 'disconnect', ...d }); return d.promise; },
  };
  const again = [], renderAgain = (s) => again.push(s);
  const second = createController({ operator: held, render: renderAgain, now: () => 123,
    setTimer() { return 0; }, clearTimer() {} });
  second.disconnect();
  second.connect();
  late.filter((p) => p.kind === 'connect').at(-1).resolve(); await settle();
  late.filter((p) => p.kind === 'presence').at(-1).resolve(snapshot()); await settle();
  second.disconnect();
  late.filter((p) => p.kind === 'disconnect').at(-1).resolve('complete'); await settle();
  assert.equal(again.at(-1).invalidation, 'complete');
  late.filter((p) => p.kind === 'disconnect')[0].reject(new Error('late')); await settle();
  assert.equal(again.at(-1).invalidation, 'complete');
});

test('disabled operator access stops polling and does not auto-retry on visibility or auto toggle', async () => {
  const h = harness();
  h.pending[0].reject(new DiscoveryError('disabled')); await settle();
  assert.equal(h.state().snapshot, null);
  assert.equal(h.state().poll, 'stopped');
  assert.match(h.state().error, /hasn.t enabled/);
  assert.equal(h.timers.size, 0);
  h.controller.setHidden(true); h.controller.setHidden(false);
  assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 0);
  assert.equal(h.timers.size, 0);
  h.controller.setAuto(false); h.controller.setAuto(true);
  assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 0);
  assert.equal(h.timers.size, 0);
  void h.controller.refresh();
  assert.equal(h.pending.filter((p) => p.kind === 'presence').length, 1);
  h.pending.filter((p) => p.kind === 'presence').at(-1).reject(new DiscoveryError('disabled')); await settle();
  assert.equal(h.state().poll, 'stopped');
  h.controller.disconnect();
});

test('filters are literal and bounded, counts overlap over full snapshot, ties deterministic', () => {
  const agents = [agent(3, { label: '[.*]', status: 'busy', acceptsControl: true, receiving: true }),
    agent(2, { label: 'same', model: { provider: 'P', id: 'M' } }), agent(1, { label: 'same' })];
  assert.deepEqual(counts(agents), { registered: 3, busy: 1, receiving: 1, control: 1 });
  assert.deepEqual(selectAgents(agents, { search: '[.*]' }).map((a) => a.agentId), [id(3)]);
  assert.equal(selectAgents(agents, { search: 'p / m' }).length, 1);
  assert.deepEqual(selectAgents(agents, { search: 'SAME' }).map((a) => a.agentId), [id(1), id(2)]);
  assert.equal(selectAgents(agents, { receiving: 'false', control: 'true' }).length, 0);
  assert.equal(selectAgents([agent(1, { label: 'x'.repeat(200) })], { search: 'x'.repeat(200) + 'ignored' }).length, 1);
  assert.equal(agents[0].agentId, id(3));
});

class Node {
  constructor(tag, doc) { this.tagName = tag.toUpperCase(); this.doc = doc; this.children = []; this.events = new Map(); this.value = ''; this.hidden = false; this.disabled = false; this.dataset = {}; this._text = ''; }
  set textContent(text) { this._text = String(text); this.replaceChildren(); }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  get firstChild() { return this.children[0]; }
  setAttribute(name, value) { this.attributes ??= new Map(); this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes?.get(name) ?? null; }
  append(...nodes) { for (const n of nodes) { n.remove(); n.parent = this; this.children.push(n); } }
  insertBefore(node, reference) {
    this.insertions = (this.insertions ?? 0) + 1;
    node.remove(); node.parent = this;
    if (reference === null) this.children.push(node);
    else this.children.splice(this.children.indexOf(reference), 0, node);
  }
  replaceChildren(...nodes) { for (const n of this.children) n.parent = null; this.children = []; this.append(...nodes); }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((n) => n !== this); this.parent = null; }
  contains(n) { return n === this || this.children.some((c) => c.contains(n)); }
  focus() { this.doc.activeElement = this; }
  addEventListener(name, fn) { const list = this.events.get(name) ?? []; list.push(fn); this.events.set(name, list); }
  fire(name, event = {}) { for (const fn of this.events.get(name) ?? []) fn({ preventDefault() {}, ...event }); }
}
const html = await readFile(new URL('../hub/priv/dashboard/index.html', import.meta.url), 'utf8');
function dom() {
  const doc = new Node('document'); doc.doc = doc; doc.hidden = false; doc.documentElement = new Node('html', doc);
  const ids = new Map();
  for (const match of html.matchAll(/<([a-z][a-z0-9]*)\b[^>]*\bid="([^"]+)"[^>]*>/g)) ids.set(match[2], new Node(match[1], doc));
  doc.createElement = (tag) => new Node(tag, doc); doc.getElementById = (id) => ids.get(id);
  ids.get('sort').value = 'label'; ids.get('theme').value = 'system';
  const win = new Node('window', doc); win.navigator = { onLine: true };
  return { doc, win, el: (id) => ids.get(id) };
}
const descendants = (node, tag) => node.children.flatMap((n) => [ ...(n.tagName === tag ? [n] : []), ...descendants(n, tag) ]);
function mockFetch(agents, { status = 200, session = nonce() } = {}) {
  return async (url) => {
    const path = String(url);
    if (path.includes('/disconnect')) return new Response(null, { status: 204 });
    if (path.includes('/session')) {
      if (status === 403) return new Response(JSON.stringify({ error: { code: 'disabled', message: 'operator api disabled' } }), { status });
      if (status === 503) return new Response(null, { status });
      return new Response(JSON.stringify({ session }));
    }
    if (status !== 200) return new Response('do not display this', { status });
    const list = typeof agents === 'function' ? agents() : agents;
    return new Response(JSON.stringify(pageDoc(list)));
  };
}

test('compact defaults keep filters and management controls folded without removing them', async () => {
  assert.match(html, /<details id="more-filters">/);
  assert.match(html, /<details id="more-actions">/);
  assert.match(html, /<details class="connection-options">/);
  assert.doesNotMatch(html, /class="metrics"/);
  const { doc, win, el } = dom(), original = globalThis.fetch;
  globalThis.fetch = mockFetch([agent(1), agent(2)]);
  const controller = mountDashboard(doc, win);
  try {
    await settle();
    assert.equal(el('cards').children.length, 2);
    assert.equal(el('clear-filters').hidden, true);
    el('host').value = 'synthetic-host'; el('host').fire('change');
    assert.equal(el('filter-summary').textContent, 'More filters (1 active)');
    assert.equal(el('clear-filters').hidden, false);
    el('needs-attention').checked = true; el('needs-attention').fire('change');
    assert.equal(el('cards').children.length, 0, 'missing task reports are not invented blockers');
    el('clear-filters').fire('click');
    assert.equal(el('needs-attention').checked, false);
    assert.equal(el('cards').children.length, 2);
  } finally { controller.disconnect(); globalThis.fetch = original; }
});

test('status colour follows explicit meaning and always has a text label', () => {
  assert.deepEqual(agentState(agent(1), null), { label: 'Not working', tone: 'neutral' });
  assert.deepEqual(agentState(agent(1, { status: 'busy' }), null), { label: 'Working', tone: 'working' });
  assert.deepEqual(agentState(agent(1), { phase: 'failed' }), { label: 'Problem reported', tone: 'danger' });
  assert.deepEqual(agentState(agent(1), { blocker: { kind: 'decision' } }), { label: 'Needs your decision', tone: 'attention' });
  assert.deepEqual(agentState(agent(1), { phase: 'completed' }), { label: 'Completed (reported)', tone: 'complete' });
  const work = new Map([[agent(1).agentId, { work: { objective: 'Repair imports', currentStep: 'Check paths', project: 'Tools' } }]]);
  assert.equal(selectAgents([agent(1)], { search: 'imports' }, work).length, 1);
});

test('mount auto-connects, disconnect stays down, reconnect, focus and late work are fenced', async () => {
  const { doc, win, el } = dom();
  const originalFetch = globalThis.fetch;
  const secret = nonce(9);
  let agents = Array.from({ length: 51 }, (_, i) => agent(i, { label: `<img src=x onerror=alert(1)>\u202e${String(i).padStart(3, '0')}`, receiving: true }));
  globalThis.fetch = mockFetch(() => agents, { session: secret });
  const controller = mountDashboard(doc, win);
  try {
    await settle();
    assert.equal(el('cards').children.length, 50); assert.equal(el('registered-count').textContent, '51');
    assert.equal(el('unlock-panel'), undefined); assert.equal(el('token'), undefined);
    assert.equal(el('reconnect').hidden, true); assert.equal(el('disconnect').hidden, false);
    assert.match(el('cards').textContent, /<img src=x onerror=alert\(1\)>/); assert.equal(descendants(el('cards'), 'IMG').length, 0);
    assert.match(el('cards').textContent, /Not working/);
    assert.doesNotMatch(el('cards').textContent, /synthetic-host|Conversation ID|Process ID/);
    assert.equal(el('status').textContent.includes(secret), false);
    const card = el('cards').children[0];
    const open = descendants(card, 'BUTTON')[0]; open.focus();
    const hostOptions = [...el('host').children], insertions = el('cards').insertions;
    await controller.refresh(); assert.equal(el('cards').children[0], card); assert.equal(doc.activeElement, open);
    hostOptions.forEach((option, i) => assert.equal(el('host').children[i], option));
    assert.equal(el('cards').insertions, insertions);
    el('host').focus(); controller.setAuto(false);
    assert.match(el('status').textContent, /paused/);
    controller.setAuto(true);
    hostOptions.forEach((option, i) => assert.equal(el('host').children[i], option));
    assert.equal(doc.activeElement, el('host'));
    assert.equal(el('cards').insertions, insertions);
    open.focus();
    agents[0] = { ...agents[0], label: `<img src=x onerror=alert(1)>\u202e000z` };
    agents[1] = { ...agents[1], label: `<img src=x onerror=alert(1)>\u202e000a` };
    await controller.refresh();
    assert.equal(el('cards').children[1], card); assert.equal(doc.activeElement, open);
    assert.equal(el('cards').insertions, insertions + 1);
    el('next').fire('click'); assert.equal(el('cards').children.length, 1); assert.equal(el('page').textContent, 'Page 2 of 2');
    el('search').value = 'unmatched'; el('search').fire('input'); assert.equal(el('cards').children.length, 0);
    assert.equal(el('registered-count').textContent, '51'); assert.match(el('empty').textContent, /match these filters/);
    agents = []; await controller.refresh(); assert.equal(el('registered-count').textContent, '0'); assert.match(el('empty').textContent, /No agents are connected/);
    el('theme').value = 'dark'; el('theme').fire('change'); assert.equal(doc.documentElement.dataset.theme, 'dark');
    win.navigator.onLine = false; win.fire('offline'); assert.equal(el('network').hidden, false);
    el('disconnect').fire('click'); await settle();
    assert.equal(el('cards').children.length, 0); assert.equal(el('search').value, ''); assert.equal(el('host').children.length, 1);
    assert.equal(el('reconnect').hidden, false); assert.equal(el('disconnect').hidden, true);
    assert.equal(doc.activeElement, el('reconnect')); assert.match(el('status').textContent, /Disconnected/);
    assert.equal(el('status').textContent.includes(secret), false);
    void controller.refresh(); await settle();
    assert.equal(el('cards').children.length, 0);
    el('reconnect').fire('click'); await settle();
    assert.equal(el('registered-count').textContent, '0'); assert.equal(el('reconnect').hidden, true);
    win.fire('pagehide'); assert.equal(el('cards').children.length, 0); assert.equal(doc.activeElement, el('reconnect'));
    win.fire('pageshow', { persisted: true }); assert.equal(el('reconnect').hidden, false);
  } finally { controller.disconnect(); globalThis.fetch = originalFetch; }
});

test('console navigation loads independent communications and disconnect clears it', async () => {
  const { doc, win, el } = dom(); const original = globalThis.fetch;
  const presenceFetch = mockFetch([agent(1)]); let reads = 0;
  const event = { schemaVersion: 1, epoch: id(99), sequence: '1', eventId: id(98), observedAt: '100',
    occurredAt: '99', source: 'relay_observed', kind: 'mail_accepted', agentId: id(2), sessionId: null,
    workId: null, threadId: null, operationId: null,
    payload: { id: id(3), from: id(1), to: id(2), kind: 'notice', acceptedAt: '99', receiving: true, bodyBytes: 5 } };
  globalThis.fetch = async (url, options) => {
    if (!String(url).includes('/api/v1/events')) return presenceFetch(url, options);
    reads++;
    return new Response(JSON.stringify({ epoch: id(99), fromSequence: '0', toSequence: '1', retainedFrom: '1',
      coverage: 'live', caughtUp: true, nextCursor: null, events: [event] }));
  };
  const controller = mountDashboard(doc, win);
  try {
    await settle(); assert.equal(reads, 0);
    descendants(el('cards'), 'BUTTON')[0].fire('click');
    assert.equal(el('inspector').hidden, false);
    assert.match(el('inspector-target').textContent, new RegExp(id(1)));
    el('inspector-session').fire('click');
    assert.match(el('inspector-body').textContent, /doesn.t support viewing/);
    el('view-communications').fire('click'); await settle();
    assert.equal(reads, 1); assert.equal(el('runtimes').hidden, true);
    assert.equal(el('communications').hidden, false);
    assert.match(el('communications-list').textContent, /Message accepted by server/);
    assert.match(el('communications-list').textContent, /Message text wasn.t saved/);
    el('view-fleet').fire('click'); assert.equal(el('runtimes').hidden, false);
    el('disconnect').fire('click'); await settle();
    assert.equal(el('communications-list').children.length, 0);
    assert.equal(el('inspector').hidden, true);
    assert.equal(el('inspector-target').textContent, '');
    assert.match(el('communications-status').textContent, /cleared/);
  } finally { controller.disconnect(); globalThis.fetch = original; }
});

test('inspector shows complete reported work as literal data, including evidence and unknowns', async () => {
  const { doc, win, el } = dom(); const original = globalThis.fetch;
  const fixtures = JSON.parse(await readFile(new URL('./fixtures/operator-work.json', import.meta.url), 'utf8'));
  const work = { ...fixtures.hostile, nextStep: null };
  const presenceFetch = mockFetch([agent(1)]);
  globalThis.fetch = async (url, options) => {
    if (!String(url).includes('/api/v1/work/')) return presenceFetch(url, options);
    return new Response(JSON.stringify({ binding: { schemaVersion: 1, agentId: id(1), sessionId: id(999),
      runtimeGeneration: '1', sessionGeneration: '1', branchId: null, activeRunId: null, registration: { epoch: id(2), generation: '1' },
      permissionRevision: '0', reportRevision: '1', capabilities: ['work.report.v1'], bindingId: id(3), workRevision: '1' },
      work, permissions: { notice: false, work: false, guidance: false, sessionRead: false, label: false, interrupt: false, content: false, workAssign: false, history: false } }));
  };
  const controller = mountDashboard(doc, win);
  try {
    await settle(); descendants(el('cards'), 'BUTTON')[0].fire('click'); await settle(); await settle();
    assert.match(el('inspector-body').textContent, /<script>alert\(1\)<\/script>/);
    assert.match(el('inspector-body').textContent, /Agent.s status: Waiting/);
    assert.match(el('inspector-body').textContent, /javascript:alert\(1\)/);
    assert.match(el('inspector-body').textContent, /Not provided/);
    assert.equal(descendants(el('inspector-body'), 'SCRIPT').length, 0);
    assert.equal(descendants(el('inspector-body'), 'A').length, 0);
    const metadata = descendants(el('inspector-body'), 'DETAILS')[0]; metadata.open = true;
    await controller.refresh(); await settle();
    assert.equal(descendants(el('inspector-body'), 'DETAILS')[0] === metadata, true);
    assert.equal(metadata.open, true);
  } finally { controller.disconnect(); globalThis.fetch = original; }
});

test('fleet work, attention, permission-gated notice and changed-target confirmation form one journey', async () => {
  const { doc, win, el } = dom(); const original = globalThis.fetch;
  const fixtures = JSON.parse(await readFile(new URL('./fixtures/operator-work.json', import.meta.url), 'utf8'));
  let revision = '1'; const creates = [];
  const workView = () => ({ binding: { schemaVersion: 1, agentId: id(1), sessionId: id(999), runtimeGeneration: '1', sessionGeneration: '1',
    activeRunId: null, branchId: null, registration: { epoch: id(9000), generation: '1' }, permissionRevision: '1', reportRevision: revision,
    capabilities: ['work.report.v1', 'notice.receive.v1'], bindingId: id(5), workRevision: revision },
    work: { ...fixtures.populated, objective: 'Investigate a reported blocker' },
    permissions: { notice: true, work: false, guidance: false, sessionRead: false, label: false, interrupt: false, content: false, workAssign: false, history: false } });
  globalThis.fetch = async (url, options) => {
    if (url.endsWith('/session')) return new Response(JSON.stringify({ session: nonce(1) }));
    if (url.endsWith('/disconnect')) return new Response(null, { status: 204 });
    if (url.endsWith('/stream')) return new Response('{}', { status: 503 });
    if (url.endsWith('/presence')) return new Response(JSON.stringify(pageDoc([agent(1)])));
    if (url.endsWith('/work')) return new Response(JSON.stringify({ epoch: id(9000), snapshotId: id(7), revision, capturedAt: 1770000000,
      page: 0, total: 1, snapshots: [workView()], nextCursor: null }));
    if (url.includes('/work/')) return new Response(JSON.stringify(workView()));
    if (url.endsWith('/operations') && options.method === 'POST') {
      const request = JSON.parse(options.body); creates.push(request);
      const { payload, ...rest } = request;
      return new Response(JSON.stringify({ ...rest, sessionId: id(999), state: 'received', createdAt: String(Date.now()),
        expiresAt: request.deadline, unsupportedWithdrawal: false, unsupported: ['message_starts_or_steers', 'attempted_not_consumed', 'no_auto_resend'], page: null }));
    }
    throw new Error('unexpected route');
  };
  const controller = mountDashboard(doc, win);
  try {
    await settle(); await settle(); await settle();
    assert.match(el('cards').textContent, /Investigate a reported blocker/);
    assert.equal(el('attention-list').children.length, 1);
    el('attention-list').children[0].fire('click'); await settle(); await settle();
    el('operation-text').value = 'A scoped operator notice'; el('operation-text').fire('input');
    assert.equal(el('operation-send').disabled, false);
    el('operation-send').fire('click'); await settle(); await settle(); await settle();
    assert.equal(creates.length, 1); assert.equal(creates[0].agentId, id(1));
    assert.equal(creates[0].workId, fixtures.populated.workId); assert.equal(creates[0].kind, 'notice');
    assert.match(el('operation-list').textContent, /Message reached the agent/);
    el('operation-text').value = 'A second draft'; el('operation-text').fire('input'); revision = '2';
    el('inspector-refresh').fire('click'); await settle(); await settle();
    assert.equal(el('operation-send').disabled, true); assert.equal(el('operation-confirm-target').hidden, false);
    assert.equal(creates.length, 1);
    el('disconnect').fire('click'); await settle();
    assert.equal(el('operation-text').value, ''); assert.equal(el('operation-list').children.length, 0);
  } finally { controller.disconnect(); globalThis.fetch = original; }
});

test('display IDs are unique over the full snapshot with suffix extension and UUID fallback', () => {
  const ids = ['abcdef00-0000-0000-0000-000000000001', 'abcdef00-0000-0000-0000-000000010001',
    'fedcba00-1000-0000-0000-000000000000', 'fedcba00-2000-0000-0000-000000000000', id(1)];
  const display = displayIds(ids.map((agentId, i) => agent(i, { agentId })));
  assert.equal(display.get(ids[0]), 'abcdef00…00001');
  assert.equal(display.get(ids[1]), 'abcdef00…10001');
  assert.equal(display.get(ids[2]), ids[2]); assert.equal(display.get(ids[3]), ids[3]);
  assert.equal(display.get(ids[4]), ids[4].slice(0, 8));
  assert.equal(new Set(display.values()).size, ids.length);
});

test('display collisions survive filters/pages; clear resets every field and page without changing totals', async () => {
  const { doc, win, el } = dom(); const originalFetch = globalThis.fetch;
  const first = 'abcdef00-0000-0000-0000-000000000001', last = 'abcdef00-0000-0000-0000-000000010001';
  const agents = Array.from({ length: 51 }, (_, i) => agent(i, { label: `Runtime ${String(i).padStart(2, '0')}` }));
  agents[0].agentId = first; agents[50].agentId = last;
  globalThis.fetch = mockFetch([...agents].sort((a, b) => a.agentId.localeCompare(b.agentId)));
  const controller = mountDashboard(doc, win);
  try {
    await settle();
    const checkNames = () => {
      const summaries = descendants(el('cards'), 'BUTTON');
      const names = summaries.map((summary) => summary.getAttribute('aria-label'));
      assert.equal(new Set(names).size, summaries.length);
      for (const summary of summaries) {
        assert.equal(summary.textContent, 'Open');
        assert.match(summary.getAttribute('aria-label'), /^Open details agent .+/);
      }
      return names;
    };
    assert.equal(checkNames()[0], 'Open details agent abcdef00…00001');
    await controller.refresh(); assert.equal(checkNames()[0], 'Open details agent abcdef00…00001');
    descendants(el('cards'), 'BUTTON')[0].fire('click');
    assert.match(el('inspector-target').textContent, new RegExp(first));
    assert.equal(el('cards').textContent.includes(first), false);
    el('next').fire('click');
    assert.deepEqual(checkNames(), ['Open details agent abcdef00…10001']);
    el('clear-filters').fire('click'); assert.equal(el('page').textContent, 'Page 1 of 2');
    for (const [field, value] of Object.entries({ search: first, host: 'synthetic-host', sort: 'host', activity: 'idle', receiving: 'false', control: 'false' })) {
      el(field).value = value; el(field).fire(field === 'search' ? 'input' : 'change');
    }
    assert.equal(el('cards').children.length, 1);
    assert.deepEqual(checkNames(), ['Open details agent abcdef00…00001']);
    await controller.refresh(); assert.deepEqual(checkNames(), ['Open details agent abcdef00…00001']);
    const firstCard = el('cards').children[0];
    const hostOption = el('host').children[1];
    el('clear-filters').fire('click');
    for (const field of ['search', 'host', 'activity', 'receiving', 'control']) assert.equal(el(field).value, '');
    assert.equal(el('sort').value, 'label'); assert.equal(doc.activeElement, el('search'));
    assert.equal(el('cards').children.length, 50); assert.equal(el('registered-count').textContent, '51');
    assert.equal(el('host').children[1], hostOption); assert.equal(el('cards').children[0], firstCard);
    assert.equal(checkNames().length, 50);
  } finally { controller.disconnect(); globalThis.fetch = originalFetch; }
});

test('controls and status colours retain accessible contrast in both themes', async () => {
  const css = await readFile(new URL('../hub/priv/dashboard/dashboard.css', import.meta.url), 'utf8');
  const expand = (hex) => hex.length === 4 ? '#' + [...hex.slice(1)].map((c) => c + c).join('') : hex;
  const luminance = (hex) => {
    const c = expand(hex).match(/[a-f0-9]{2}/gi).map((h) => parseInt(h, 16) / 255).map((v) => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
    return c[0] * .2126 + c[1] * .7152 + c[2] * .0722;
  };
  const checked = new Set();
  for (const match of css.matchAll(/--panel: (#[a-f0-9]{3}(?:[a-f0-9]{3})?);[^}]*?--control-line: (#[a-f0-9]{3}(?:[a-f0-9]{3})?);/g)) {
    const values = [luminance(match[1]), luminance(match[2])].sort((a, b) => b - a);
    assert.ok((values[0] + .05) / (values[1] + .05) >= 3);
    checked.add(expand(match[1]));
  }
  assert.deepEqual(checked, new Set(['#ffffff', '#1a2430']));
  assert.match(css, /input, select, button[^}]+var\(--control-line\)/);
  assert.match(css, /@media \(min-width: 1100px\)/);
  for (const tone of ['danger', 'attention', 'working', 'complete']) {
    let palettes = 0;
    const pattern = new RegExp(`--${tone}-ink: (#[a-f0-9]{6}); --${tone}-bg: (#[a-f0-9]{6});`, 'g');
    for (const match of css.matchAll(pattern)) {
      const [light, dark] = [luminance(match[1]), luminance(match[2])].sort((a, b) => b - a);
      assert.ok((light + .05) / (dark + .05) >= 4.5, `${tone} text contrast`); palettes++;
    }
    assert.ok(palettes >= 2, `${tone} light and dark palettes`);
  }
  assert.match(css, /\.card \{ display: grid; grid-template-columns: minmax\(0, 1fr\) auto 70px/);
  assert.doesNotMatch(html, /role="(?:table|row|cell)"/);
});

test('failed snapshots are cleared; disabled operator API does not ask for a hub token', async () => {
  const { doc, win, el } = dom(); const originalFetch = globalThis.fetch; let status = 200;
  globalThis.fetch = mockFetch([agent(1)], { status: 200 });
  const live = mockFetch([agent(1)]);
  globalThis.fetch = async (url, options) => {
    if (status === 200) return live(url, options);
    if (String(url).includes('/session')) return live(url, options);
    return new Response('do not display this', { status });
  };
  const controller = mountDashboard(doc, win);
  try {
    await settle();
    assert.equal(el('cards').children.length, 1);
    status = 409; await controller.refresh(); assert.equal(el('cards').children.length, 0); assert.match(el('status').textContent, /changed/);
    assert.equal(el('registered-count').textContent, '--'); assert.equal(el('status').textContent.includes('do not display'), false);
    controller.disconnect();
  } finally { globalThis.fetch = originalFetch; }
  const disabled = dom();
  globalThis.fetch = async () => new Response(JSON.stringify({ error: { code: 'disabled', message: 'operator api disabled' } }), { status: 403 });
  const blocked = mountDashboard(disabled.doc, disabled.win);
  try {
    await settle();
    assert.match(disabled.el('status').textContent, /hasn.t enabled/i);
    assert.match(disabled.el('status').textContent, /Automatic updates stopped/);
    assert.doesNotMatch(disabled.el('status').textContent, /Next automatic read/);
    assert.equal(disabled.el('cards').children.length, 0);
    assert.doesNotMatch(disabled.el('status').textContent, /Unlock|bearer|password|token field/i);
    assert.equal(disabled.el('token'), undefined);
  } finally { blocked.disconnect(); globalThis.fetch = originalFetch; }
});

test('static accessibility and containment hooks have no inline code, storage or peer HTML sink', async () => {
  const js = await readFile(new URL('../hub/priv/dashboard/dashboard.js', import.meta.url), 'utf8');
  const css = await readFile(new URL('../hub/priv/dashboard/dashboard.css', import.meta.url), 'utf8');
  assert.doesNotMatch(js, /innerHTML|outerHTML|insertAdjacentHTML|localStorage|sessionStorage|document\.cookie|console\.|EventSource|serviceWorker/);
  assert.doesNotMatch(html, /\son[a-z]+\s*=|<style\b|\sstyle=/i);
  assert.doesNotMatch(html, /type="password"|id="token"|id="unlock-form"|Unlock presence viewer/);
  assert.match(html, /Disconnect and clear/); assert.match(html, />Reconnect</);
  assert.match(html, /maxlength="200"/);
  assert.match(html, /aria-live="polite"/); assert.match(html, /href="#console-content">Skip to console content/);
  assert.match(html, /id="console-content"[^>]*tabindex="-1"/);
  assert.match(html, /allow work requests/);
  assert.match(css, /unicode-bidi: plaintext/); assert.match(css, /overflow-wrap: anywhere/);
  assert.match(css, /prefers-color-scheme: dark/); assert.match(css, /:focus-visible/); assert.match(css, /max-width: 440px/);
});
