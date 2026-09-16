import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { ExtensionContext } from '@earendil-works/pi-coding-agent';
import { createRuntime } from '../extension/runtime.ts';
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const work = JSON.parse(readFileSync(new URL('./fixtures/operator-work.json', import.meta.url), 'utf8')).allNull;
const settle = async () => { for (let n = 0; n < 80; n++) await Promise.resolve(); };
function fixture(announceStatus = 200) {
  const calls: Array<{ method?: string; path: string; body?: string }> = [];
  const tasks = new Map<number, { fn: () => void; delay: number }>(); let next = 0, time = 0;
  const ctx = { mode: 'tui', cwd: '/synthetic', model: null, isIdle: () => true,
    sessionManager: { getSessionId: () => id, getBranch: () => [], getLeafId: () => null },
    ui: { notify() {}, setStatus() {}, confirm: async () => false } } as unknown as ExtensionContext;
  const runtime = createRuntime({ env: { PI_AGENT_BUS_TOKEN: 'synthetic', PI_AGENT_BUS_URL: 'http://localhost:7420' },
    uuid: () => id, now: () => time, hostname: () => 'synthetic', pid: () => 12,
    timers: { setTimeout(fn, delay) { const key = ++next; tasks.set(key, { fn, delay }); return key; }, clearTimeout(key) { tasks.delete(key as number); } },
    subscribe: async () => new Promise<never>(() => {}),
    fetch: async (url, options) => {
      const path = new URL(url).pathname; calls.push({ method: options?.method, path, body: options?.body });
      if (path === '/v1/operator/announce') {
        if (announceStatus !== 200) return new Response('{}', { status: announceStatus });
        const doc = JSON.parse(options!.body!); delete doc.work; delete doc.permissions;
        return new Response(JSON.stringify({ ...doc, registration: { epoch: id, generation: '1' }, bindingId: id, workRevision: '1' }));
      }
      return new Response(null, { status: 204 });
    },
  });
  return { runtime, ctx, calls, tasks, heartbeat: () => {
    time += 5000; const item = [...tasks].find(([, v]) => v.delay === 5000); assert.ok(item);
    tasks.delete(item[0]); item[1].fn();
  } };
}
test('successful registration announces metadata without altering legacy presence schema', async () => {
  const f = fixture(); f.runtime.sessionStart({}, f.ctx);
  try {
    await settle();
    assert.equal(f.calls[0].method, 'PUT');
    const announcement = f.calls.find(c => c.path === '/v1/operator/announce'); assert.ok(announcement);
    const doc = JSON.parse(announcement.body!);
    assert.equal(doc.work.objective, null); assert.equal(doc.permissions.sessionRead, false);
    assert.equal(doc.permissions.label, false); assert.equal(doc.permissions.interrupt, false);
    assert.equal(doc.permissions.content, false);
    assert.equal(JSON.parse(f.calls[0].body!).work, undefined);
  } finally { await f.runtime.sessionShutdown(); }
});
test('announcement 401 stops the heartbeat and every later metadata producer', async () => {
  const f = fixture(401); f.runtime.sessionStart({}, f.ctx);
  try {
    await settle(); assert.equal(f.runtime.status(), 'down'); assert.equal(f.tasks.size, 0);
    const count = f.calls.length;
    f.runtime.refresh(f.ctx); f.runtime.reportWork(work); f.runtime.setBusy(true, f.ctx);
    await settle(); assert.equal(f.calls.length, count);
  } finally { await f.runtime.sessionShutdown(); }
});

test('explicit work reports and branch changes publish exact current metadata', async () => {
  const f = fixture(); f.runtime.sessionStart({}, f.ctx);
  try {
    await settle();
    f.runtime.reportWork({ ...work, workId: id, currentStep: 'Checking', nextStep: 'Review' });
    await settle();
    let doc = JSON.parse(f.calls.filter(c => c.path === '/v1/operator/announce').at(-1)!.body!);
    assert.equal(doc.work.currentStep, 'Checking'); assert.equal(doc.work.phase, null);
    const before = BigInt(doc.sessionGeneration);
    f.runtime.refresh(f.ctx, true); await settle();
    doc = JSON.parse(f.calls.filter(c => c.path === '/v1/operator/announce').at(-1)!.body!);
    assert.equal(BigInt(doc.sessionGeneration), before + 1n);
  } finally { await f.runtime.sessionShutdown(); }
});
