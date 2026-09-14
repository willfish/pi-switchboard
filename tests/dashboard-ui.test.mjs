import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createController, counts, selectAgents, displayIds, mountDashboard } from '../hub/priv/dashboard/dashboard.js';
import { DiscoveryError } from '../hub/priv/dashboard/protocol.js';

const id = (n) => `${n.toString(16).padStart(8, '0')}-0000-0000-0000-000000000000`;
const agent = (n, patch = {}) => ({ agentId: id(n), sessionId: id(999), host: 'synthetic-host', cwd: '/synthetic',
  sessionName: 'shared session', label: `Runtime ${n}`, model: null, status: 'idle', pid: n + 1,
  updatedAt: 1770000000, receiving: false, acceptsControl: false, ...patch });
const snapshot = (agents = []) => ({ epoch: id(9000), snapshotId: id(9001), revision: '1',
  capturedAt: 1770000000, total: agents.length, agents });
const settle = async () => { for (let n = 0; n < 20; n++) await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
function harness() {
  const pending = [], states = [], timers = new Map(); let serial = 0;
  const controller = createController({ load: (token, { signal }) => {
    const d = deferred(); pending.push({ ...d, token, signal }); return d.promise;
  }, render: (s) => states.push(s), now: () => 123,
  setTimer: (fn, ms) => { timers.set(++serial, { fn, ms }); return serial; }, clearTimer: (key) => timers.delete(key) });
  return { controller, pending, states, timers, state: () => states.at(-1), tick() {
    const [key, t] = timers.entries().next().value; timers.delete(key); t.fn(); return t.ms;
  } };
}

test('single flight, historical refresh, failure clearing, backoff, hidden pause and return', async () => {
  const h = harness(); h.controller.unlock('synthetic');
  assert.equal(h.state().snapshot, null); assert.equal(h.state().loading, true);
  void h.controller.refresh(); assert.equal(h.pending.length, 1);
  const original = snapshot([agent(1)]); h.pending[0].resolve(original); await settle();
  assert.equal(h.state().snapshot, original); assert.equal(h.state().lastSuccess, 123);
  assert.equal(h.tick(), 15000); assert.equal(h.state().snapshot, original);
  h.pending[1].reject(new DiscoveryError('reset')); await settle();
  assert.equal(h.state().snapshot, null); assert.equal(h.state().lastSuccess, 123); assert.match(h.state().error, /changed/);
  assert.equal(h.tick(), 30000); h.pending[2].reject(new Error('REMOTE SECRET')); await settle();
  assert.equal(h.state().error.includes('REMOTE SECRET'), false); assert.equal([...h.timers.values()][0].ms, 60000);
  h.controller.setHidden(true); assert.equal(h.timers.size, 0);
  h.controller.setHidden(false); assert.equal(h.pending.length, 4);
  h.pending[3].resolve(snapshot()); await settle(); assert.equal([...h.timers.values()][0].ms, 15000);
  h.controller.setAuto(false); assert.equal(h.timers.size, 0);
  h.controller.setHidden(true); h.controller.setHidden(false); assert.equal(h.pending.length, 4);
  h.controller.lock();
});

test('hidden pending reads settle without scheduling; return and auto changes never overlap', async () => {
  for (const reject of [false, true]) {
    for (const returnBeforeCompletion of [false, true]) {
      const h = harness(); h.controller.unlock('synthetic');
      h.controller.setHidden(true);
      assert.equal(h.pending[0].signal.aborted, false);
      assert.equal(h.timers.size, 0);
      if (returnBeforeCompletion) h.controller.setHidden(false);
      void h.controller.refresh();
      assert.equal(h.pending.length, 1);
      if (reject) h.pending[0].reject(new DiscoveryError('transport'));
      else h.pending[0].resolve(snapshot([agent(1)]));
      await settle();
      assert.equal(h.state().loading, false);
      assert.equal(h.state().snapshot === null, reject);
      if (returnBeforeCompletion) {
        assert.equal(h.timers.size, 1);
        assert.equal([...h.timers.values()][0].ms, reject ? 30000 : 15000);
      } else {
        assert.equal(h.timers.size, 0);
        h.controller.setHidden(false);
        assert.equal(h.pending.length, 2);
        void h.controller.refresh(); assert.equal(h.pending.length, 2);
        h.pending[1].resolve(snapshot()); await settle();
        assert.equal(h.timers.size, 1);
      }
      h.controller.lock();
    }
  }
  for (const reject of [false, true]) {
    const h = harness(); h.controller.unlock('synthetic'); h.controller.setAuto(false);
    h.controller.setHidden(true); h.controller.setHidden(false);
    void h.controller.refresh(); assert.equal(h.pending.length, 1);
    if (reject) h.pending[0].reject(new DiscoveryError('transport'));
    else h.pending[0].resolve(snapshot());
    await settle(); assert.equal(h.timers.size, 0); assert.equal(h.pending.length, 1);
    h.controller.setHidden(true); h.controller.setHidden(false); assert.equal(h.pending.length, 1);
    void h.controller.refresh(); assert.equal(h.pending.length, 2);
    h.controller.setAuto(true); assert.equal(h.timers.size, 0);
    void h.controller.refresh(); assert.equal(h.pending.length, 2);
    h.pending[1].resolve(snapshot()); await settle(); assert.equal(h.timers.size, 1);
    h.controller.lock();
  }
});

test('lock, re-unlock and 401 fence late success and late rejection without leaking token into state', async () => {
  const h = harness(); h.controller.unlock('first-synthetic'); h.controller.lock();
  assert.equal(h.pending[0].signal.aborted, true);
  h.controller.unlock('second-synthetic'); h.pending[0].resolve(snapshot([agent(1)])); await settle();
  assert.equal(h.state().snapshot, null); assert.equal(h.state().loading, true);
  h.pending[1].reject(new DiscoveryError('unauthorized')); await settle();
  assert.equal(h.state().unlocked, false); assert.equal(h.state().lastSuccess, null); assert.equal(h.timers.size, 0);
  h.controller.unlock('third-synthetic'); h.controller.lock(); h.pending[2].reject(new DiscoveryError('unauthorized')); await settle();
  assert.equal(h.state().error, '');
  assert.equal(JSON.stringify(h.states).includes('synthetic'), false);
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

// Minimal DOM exercises actual rendering and events without introducing a DOM dependency.
// It is not layout, accessibility-tree or browser security validation.
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
  for (const match of html.matchAll(/<([a-z]+)\b[^>]*\bid="([^"]+)"[^>]*>/g)) ids.set(match[2], new Node(match[1], doc));
  doc.createElement = (tag) => new Node(tag, doc); doc.getElementById = (id) => ids.get(id);
  ids.get('sort').value = 'label'; ids.get('theme').value = 'system';
  const win = new Node('window', doc); win.navigator = { onLine: true };
  return { doc, win, el: (id) => ids.get(id) };
}
const descendants = (node, tag) => node.children.flatMap((n) => [ ...(n.tagName === tag ? [n] : []), ...descendants(n, tag) ]);

test('actual DOM rendering: hostile markup, 50-row pages, complete counts, detail focus and empty states', async () => {
  const { doc, win, el } = dom();
  const originalFetch = globalThis.fetch;
  const hostile = '<img src=x onerror=alert(1)>\u202e';
  let agents = Array.from({ length: 51 }, (_, i) => agent(i, { label: `${hostile}${String(i).padStart(3, '0')}`, receiving: true }));
  globalThis.fetch = async () => new Response(JSON.stringify({ ...snapshot(agents), page: 0, nextCursor: null }));
  const controller = mountDashboard(doc, win);
  try {
    el('token').value = 'synthetic-only'; el('unlock-form').fire('submit'); assert.equal(el('token').value, ''); await settle();
    assert.equal(el('cards').children.length, 50); assert.equal(el('registered-count').textContent, '51');
    assert.match(el('cards').textContent, /<img src=x onerror=alert\(1\)>/); assert.equal(descendants(el('cards'), 'IMG').length, 0);
    const details = descendants(el('cards'), 'DETAILS')[0]; details.open = true;
    const summary = descendants(details, 'SUMMARY')[0]; summary.focus();
    const hostOptions = [...el('host').children], insertions = el('cards').insertions;
    await controller.refresh(); assert.equal(descendants(el('cards'), 'DETAILS')[0], details); assert.equal(details.open, true); assert.equal(doc.activeElement, summary);
    hostOptions.forEach((option, i) => assert.equal(el('host').children[i], option));
    assert.equal(el('cards').insertions, insertions);
    el('host').focus(); controller.setAuto(false); controller.setAuto(true);
    hostOptions.forEach((option, i) => assert.equal(el('host').children[i], option));
    assert.equal(doc.activeElement, el('host'));
    assert.equal(el('cards').insertions, insertions);
    summary.focus();
    agents[0] = { ...agents[0], label: `${hostile}000z` };
    agents[1] = { ...agents[1], label: `${hostile}000a` };
    await controller.refresh();
    assert.equal(descendants(el('cards'), 'DETAILS')[1], details); assert.equal(details.open, true); assert.equal(doc.activeElement, summary);
    assert.equal(el('cards').insertions, insertions + 1);
    el('next').fire('click'); assert.equal(el('cards').children.length, 1); assert.equal(el('page').textContent, 'Page 2 of 2');
    el('search').value = 'unmatched'; el('search').fire('input'); assert.equal(el('cards').children.length, 0);
    assert.equal(el('registered-count').textContent, '51'); assert.match(el('empty').textContent, /match these filters/);
    agents = []; await controller.refresh(); assert.equal(el('registered-count').textContent, '0'); assert.match(el('empty').textContent, /No runtimes registered/);
    el('theme').value = 'dark'; el('theme').fire('change'); assert.equal(doc.documentElement.dataset.theme, 'dark');
    win.navigator.onLine = false; win.fire('offline'); assert.equal(el('network').hidden, false);
    win.fire('pagehide'); assert.equal(el('cards').children.length, 0); assert.equal(el('search').value, ''); assert.equal(el('host').children.length, 1);
    assert.equal(doc.activeElement, el('token')); assert.equal(el('unlock-panel').hidden, false);
    win.fire('pageshow', { persisted: true }); assert.equal(el('token').value, '');
  } finally { controller.lock(); globalThis.fetch = originalFetch; }
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
  globalThis.fetch = async () => new Response(JSON.stringify({ ...snapshot(agents), agents: [...agents].sort((a, b) => a.agentId.localeCompare(b.agentId)), page: 0, nextCursor: null }));
  const controller = mountDashboard(doc, win);
  try {
    el('token').value = 'synthetic'; el('unlock-form').fire('submit'); await settle();
    const checkNames = () => {
      const summaries = descendants(el('cards'), 'SUMMARY');
      const names = summaries.map((summary) => summary.getAttribute('aria-label'));
      assert.equal(new Set(names).size, summaries.length);
      for (const summary of summaries) {
        assert.equal(summary.textContent, 'Runtime details');
        assert.match(summary.getAttribute('aria-label'), /^Runtime details for .+/);
      }
      return names;
    };
    assert.equal(checkNames()[0], 'Runtime details for abcdef00…00001');
    await controller.refresh(); assert.equal(checkNames()[0], 'Runtime details for abcdef00…00001');
    assert.match(el('cards').children[0].textContent, /abcdef00…00001/);
    assert.match(el('cards').children[0].textContent, new RegExp(first));
    el('next').fire('click'); assert.match(el('cards').textContent, /abcdef00…10001/);
    assert.deepEqual(checkNames(), ['Runtime details for abcdef00…10001']);
    el('clear-filters').fire('click'); assert.equal(el('page').textContent, 'Page 1 of 2');
    for (const [field, value] of Object.entries({ search: first, host: 'synthetic-host', sort: 'host', activity: 'idle', receiving: 'false', control: 'false' })) {
      el(field).value = value; el(field).fire(field === 'search' ? 'input' : 'change');
    }
    assert.equal(el('cards').children.length, 1); assert.match(el('cards').textContent, /abcdef00…00001/);
    assert.deepEqual(checkNames(), ['Runtime details for abcdef00…00001']);
    await controller.refresh(); assert.deepEqual(checkNames(), ['Runtime details for abcdef00…00001']);
    const details = descendants(el('cards'), 'DETAILS')[0]; details.open = true;
    const hostOption = el('host').children[1];
    el('clear-filters').fire('click');
    for (const field of ['search', 'host', 'activity', 'receiving', 'control']) assert.equal(el(field).value, '');
    assert.equal(el('sort').value, 'label'); assert.equal(doc.activeElement, el('search'));
    assert.equal(el('cards').children.length, 50); assert.equal(el('registered-count').textContent, '51');
    assert.equal(el('host').children[1], hostOption); assert.equal(descendants(el('cards'), 'DETAILS')[0], details); assert.equal(details.open, true);
    assert.equal(checkNames().length, 50);
  } finally { controller.lock(); globalThis.fetch = originalFetch; }
});

test('control border colors meet 3:1 against their panels; desktop layout keeps native articles/details', async () => {
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
  assert.match(css, /@media \(min-width: 1400px\) \{ \.filters \{ grid-template-columns: minmax\(0, 2fr\) repeat\(5, minmax\(0, 1fr\)\)/);
  assert.match(css, /\.card details \{ grid-column: 1 \/ -1/);
  assert.doesNotMatch(html, /role="(?:table|row|cell)"/);
});

test('actual UI clears snapshot on failure and restores token focus on 401', async () => {
  const { doc, win, el } = dom(); const originalFetch = globalThis.fetch; let status = 200;
  globalThis.fetch = async () => status === 200 ? new Response(JSON.stringify({ ...snapshot([agent(1)]), page: 0, nextCursor: null })) : new Response('do not display this', { status });
  const controller = mountDashboard(doc, win);
  try {
    el('token').value = 'synthetic'; el('unlock-form').fire('submit'); await settle();
    status = 409; await controller.refresh(); assert.equal(el('cards').children.length, 0); assert.match(el('status').textContent, /changed/);
    assert.equal(el('registered-count').textContent, '--'); assert.equal(el('status').textContent.includes('do not display'), false);
    status = 401; await controller.refresh(); assert.equal(doc.activeElement, el('token')); assert.equal(el('unlock-panel').hidden, false);
  } finally { controller.lock(); globalThis.fetch = originalFetch; }
});

test('static accessibility and containment hooks have no inline code, storage or peer HTML sink', async () => {
  const js = await readFile(new URL('../hub/priv/dashboard/dashboard.js', import.meta.url), 'utf8');
  const css = await readFile(new URL('../hub/priv/dashboard/dashboard.css', import.meta.url), 'utf8');
  assert.doesNotMatch(js, /innerHTML|outerHTML|insertAdjacentHTML|localStorage|sessionStorage|document\.cookie|console\.|EventSource|serviceWorker/);
  assert.doesNotMatch(html, /\son[a-z]+\s*=|<style\b|\sstyle=/i);
  assert.match(html, /type="password" autocomplete="off"/); assert.match(html, /maxlength="200"/);
  assert.match(html, /aria-live="polite"/); assert.match(html, /Skip to runtimes/);
  assert.match(css, /unicode-bidi: plaintext/); assert.match(css, /overflow-wrap: anywhere/);
  assert.match(css, /prefers-color-scheme: dark/); assert.match(css, /:focus-visible/); assert.match(css, /max-width: 440px/);
});
