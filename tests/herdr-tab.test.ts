import assert from 'node:assert/strict';
import { test } from 'node:test';
import { nameUnlabelledTab, type TabOwnership } from '../extension/herdr-tab.ts';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const env = { HERDR_ENV: '1', HERDR_SOCKET_PATH: '/synthetic/herdr.sock', HERDR_PANE_ID: 'w1:p2', HERDR_TAB_ID: 'stale-tab' };
function fixture(shown = '3') {
  const calls: Array<[string, Record<string, string>]> = [];
  let pane = { pane_id: 'w1:p2', tab_id: 'w1:t1', workspace_id: 'w1' };
  let panes = [pane];
  const call = async (method: string, params: Record<string, string>) => {
    calls.push([method, params]);
    if (method === 'pane.get') return { pane };
    if (method === 'pane.list') return { panes };
    if (method === 'tab.get') return { tab: { number: 26, label: shown } };
    if (method === 'tab.rename') { shown = params.label; return { tab: { label: shown } }; }
    throw new Error('unexpected method');
  };
  return { call, calls, shown: () => shown, rename: (label: string) => { shown = label; },
    move: (tab: string) => { pane = { ...pane, tab_id: tab }; panes = [pane]; },
    peers: (values: typeof panes) => { panes = values; },
    writes: () => calls.filter(([method]) => method === 'tab.rename'),
  };
}

test('names the actual caller tab, preserving its visible index rather than tab.number', async () => {
  const f = fixture();
  const owned = await nameUnlabelledTab('Improve session labels', env, f.call);
  assert.equal(f.shown(), '3 Improve session labels');
  assert.deepEqual(owned, { socket: env.HERDR_SOCKET_PATH, pane: 'w1:p2', tab: 'w1:t1', label: f.shown() });
  assert.deepEqual(f.writes(), [['tab.rename', { tab_id: 'w1:t1', label: '3 Improve session labels' }]]);
  assert.equal(JSON.stringify(f.calls).includes('stale-tab'), false);
});

test('manual names, including number plus text, are not implicitly owned', async () => {
  for (const label of ['', 'binds', '1 binds', '1 <skill name="broken"', '1 Improve session labels']) {
    const f = fixture(label);
    await nameUnlabelledTab('New task', env, f.call);
    assert.deepEqual(f.writes(), []);
  }
});

test('only the oldest pane can own a split tab; another tab does not participate in the election', async () => {
  const f = fixture();
  f.peers([{ pane_id: 'w1:p1', tab_id: 'other-tab', workspace_id: 'w1' },
    { pane_id: 'w1:p10', tab_id: 'w1:t1', workspace_id: 'w1' },
    { pane_id: 'w1:p2', tab_id: 'w1:t1', workspace_id: 'w1' }]);
  await nameUnlabelledTab('Root task', env, f.call);
  assert.equal(f.writes().length, 1);
  const helper = fixture();
  helper.peers([{ pane_id: 'w1:p1', tab_id: 'w1:t1', workspace_id: 'w1' },
    { pane_id: 'w1:p2', tab_id: 'w1:t1', workspace_id: 'w1' }]);
  await nameUnlabelledTab('Helper task', env, helper.call);
  assert.deepEqual(helper.writes(), []);
});

test('owned titles can evolve, identical titles cause no write, and manual renames end ownership', async () => {
  const f = fixture();
  const previous = await nameUnlabelledTab('Review parser', env, f.call) as TabOwnership;
  const updated = await nameUnlabelledTab('Fix parser', env, f.call, { previous }) as TabOwnership;
  assert.equal(f.shown(), '3 Fix parser');
  await nameUnlabelledTab('Fix parser', env, f.call, { previous: updated });
  assert.equal(f.writes().length, 2);
  f.rename('3 My manual tab');
  await nameUnlabelledTab('Test parser', env, f.call, { previous: updated });
  assert.equal(f.shown(), '3 My manual tab');
  assert.equal(f.writes().length, 2);
});

test('ownership cannot cross sockets, panes, or tabs', async () => {
  for (const changed of [{ socket: '/other.sock' }, { pane: 'w1:p99' }, { tab: 'w1:t99' }]) {
    const f = fixture('3 Previous title');
    const previous = { socket: env.HERDR_SOCKET_PATH, pane: 'w1:p2', tab: 'w1:t1', label: f.shown(), ...changed };
    await nameUnlabelledTab('New task', env, f.call, { previous });
    assert.equal(f.writes().length, 0);
  }
});

test('pane movement, a manual rename during lookup, and session invalidation all fence the write', async () => {
  for (const kind of ['move', 'rename', 'session']) {
    const f = fixture(); let current = true; let reads = 0;
    await nameUnlabelledTab('New task', env, async (method, params) => {
      const result = await f.call(method, params);
      if (method === 'tab.get' && ++reads === 1) {
        if (kind === 'move') f.move('w1:t2');
        if (kind === 'rename') f.rename('Manual title');
        if (kind === 'session') current = false;
      }
      return result;
    }, { isCurrent: () => current });
    assert.equal(f.writes().length, 0, kind);
  }
});

test('a moved pane can name its new numeric tab without reusing old ownership', async () => {
  const f = fixture();
  const previous = await nameUnlabelledTab('First task', env, f.call) as TabOwnership;
  f.move('w1:t2'); f.rename('4');
  const next = await nameUnlabelledTab('First task', env, f.call, { previous });
  assert.equal(next?.tab, 'w1:t2');
  assert.equal(f.shown(), '4 First task');
});

test('socket requests use newline framing and include current pane topology', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'switchboard-herdr-'));
  const socketPath = join(dir, 'herdr.sock'); const f = fixture();
  const server = createServer(socket => {
    let input = '';
    socket.on('data', async chunk => {
      input += chunk.toString();
      if (!input.includes('\n')) return;
      const request = JSON.parse(input.slice(0, input.indexOf('\n')));
      const result = await f.call(request.method, request.params);
      socket.write(`${JSON.stringify({ id: request.id, result })}\n`);
    });
  });
  try {
    await new Promise<void>(resolve => server.listen(socketPath, resolve));
    await nameUnlabelledTab('Improve session labels', { ...env, HERDR_SOCKET_PATH: socketPath });
    assert.equal(f.writes().length, 1);
    assert.equal(f.shown(), '3 Improve session labels');
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});

test('non-Herdr, unbound, stale and markup inputs have no socket effects', async () => {
  let called = false;
  const call = async () => { called = true; };
  await nameUnlabelledTab('Task', { ...env, HERDR_ENV: '0' }, call);
  await nameUnlabelledTab('Task', { ...env, HERDR_PANE_ID: '' }, call);
  await nameUnlabelledTab('Task', env, call, { isCurrent: () => false });
  await nameUnlabelledTab('<skill name=oops>', env, call);
  assert.equal(called, false);
});
