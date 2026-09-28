import assert from 'node:assert/strict';
import { test } from 'node:test';
import { nameUnlabelledTab } from '../extension/herdr-tab.ts';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const env = { HERDR_ENV: '1', HERDR_SOCKET_PATH: '/synthetic/herdr.sock', HERDR_PANE_ID: 'w1:p2' };

test('renames only the tab containing this pane and keeps its number', async () => {
  const calls: Array<[string, Record<string, string>]> = [];
  await nameUnlabelledTab('Updating search dashboard', env, async (method, params) => {
    calls.push([method, params]);
    if (method === 'pane.get') return { pane: { tab_id: 'w1:t1' } };
    if (method === 'tab.get') return { tab: { number: 1, label: '1' } };
    return { tab: { label: '1 Updating search dashboard' } };
  });
  assert.deepEqual(calls, [
    ['pane.get', { pane_id: 'w1:p2' }],
    ['tab.get', { tab_id: 'w1:t1' }],
    ['tab.rename', { tab_id: 'w1:t1', label: '1 Updating search dashboard' }],
  ]);
});

test('preserves a manually named tab and a tab already named by the agent', async () => {
  for (const label of ['My work', '1 Updating search dashboard']) {
    const calls: string[] = [];
    await nameUnlabelledTab('New task', env, async (method) => {
      calls.push(method);
      return method === 'pane.get' ? { pane: { tab_id: 'w1:t1' } } : { tab: { number: 1, label } };
    });
    assert.deepEqual(calls, ['pane.get', 'tab.get']);
  }
});

test('uses Herdr newline-framed socket responses', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'switchboard-herdr-'));
  const socketPath = join(dir, 'herdr.sock');
  const methods: string[] = [];
  const server = createServer(socket => {
    let input = '';
    socket.on('data', chunk => {
      input += chunk.toString();
      if (!input.includes('\n')) return;
      const request = JSON.parse(input.slice(0, input.indexOf('\n')));
      methods.push(request.method);
      const result = request.method === 'pane.get' ? { pane: { tab_id: 'w1:t1' } } :
        request.method === 'tab.get' ? { tab: { number: 1, label: '1' } } : { tab: { label: request.params.label } };
      socket.write(`${JSON.stringify({ id: request.id, result })}\n`);
    });
  });
  try {
    await new Promise<void>(resolve => server.listen(socketPath, resolve));
    await nameUnlabelledTab('Updating search dashboard', { ...env, HERDR_SOCKET_PATH: socketPath });
    assert.deepEqual(methods, ['pane.get', 'tab.get', 'tab.rename']);
  } finally {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});

test('ignores non-Herdr or unbound sessions', async () => {
  let called = false;
  await nameUnlabelledTab('Task', { ...env, HERDR_ENV: '0' }, async () => { called = true; });
  await nameUnlabelledTab('Task', { ...env, HERDR_PANE_ID: '' }, async () => { called = true; });
  assert.equal(called, false);
});
