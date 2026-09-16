import test from 'node:test';
import assert from 'node:assert/strict';
import type { ExtensionContext } from '@earendil-works/pi-coding-agent';
import { createSessionProjection } from '../extension/operator-session-projection.ts';
const sessionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
function fixture(count: number, text = 'Visible') {
  const entries = new Map<string, any>(); let leaf = `e${count}`;
  for (let i = 1; i <= count; i++) entries.set(`e${i}`, { type: 'message', id: `e${i}`, parentId: i === 1 ? null : `e${i - 1}`,
    message: { role: 'user', content: text } });
  const ctx = { sessionManager: { getSessionId: () => sessionId, getLeafId: () => leaf, getEntry: (id: string) => entries.get(id) } } as unknown as ExtensionContext;
  return { entries, ctx, setLeaf: (id: string) => { leaf = id; } };
}
test('projection pages freeze ancestry and require issued generation-bound handles', () => {
  let now = 0, serial = 0; const f = fixture(71);
  const projection = createSessionProjection({ now: () => now, uuid: () => `cursor-${++serial}` });
  const first = projection.read(f.ctx, '1', null);
  assert.equal(first.records.length, 64); assert.equal(first.leafId, 'e71'); assert.equal(first.records[0].entryId, 'e8');
  f.entries.set('e72', { type: 'message', id: 'e72', parentId: 'e71', message: { role: 'user', content: 'Newer' } }); f.setLeaf('e72');
  const older = projection.read(f.ctx, '1', first.nextLeafId);
  assert.equal(older.leafId, 'e71'); assert.equal(older.records.length, 7); assert.equal(older.nextLeafId, null);
  assert.throws(() => projection.read(f.ctx, '1', 'e7'), /handle/);
  assert.throws(() => projection.read(f.ctx, '2', first.nextLeafId), /handle/);
  now = 30000; assert.throws(() => projection.read(f.ctx, '1', first.nextLeafId), /handle/);
});
test('text previews and encoded page budgets both apply without splitting Unicode', () => {
  const f = fixture(70, '😀'.repeat(10000)); const projection = createSessionProjection();
  const page = projection.read(f.ctx, '1', null);
  assert.ok(Buffer.byteLength(JSON.stringify(page)) <= 524288);
  assert.ok(page.records.length < 64); assert.equal(page.truncated, true); assert.ok(page.nextLeafId);
  for (const record of page.records) { assert.ok(Buffer.byteLength(record.text) <= 16384); assert.equal(record.text.endsWith('😀'), true); }
  const escaped = fixture(64, '\u0001'.repeat(16384));
  assert.ok(Buffer.byteLength(JSON.stringify(createSessionProjection().read(escaped.ctx, '1', null))) <= 524288);
});
test('compaction and unrecognized custom state are omitted without reading private fields', () => {
  const f = fixture(3); f.entries.set('e2', { type: 'compaction', id: 'e2', parentId: 'e1', summary: 'PRIVATE_SUMMARY', retainedTail: [{ role: 'user', content: 'PRIVATE_TAIL' }] });
  const page = createSessionProjection().read(f.ctx, '1', null);
  assert.equal(page.records.length, 1); assert.equal(page.omitted, 1); assert.equal(page.truncated, true);
  assert.equal(JSON.stringify(page).includes('PRIVATE'), false); assert.equal(page.nextLeafId, null);
  f.entries.set('e2', { type: 'custom', id: 'e2', parentId: 'e1', customType: 'private', get data() { throw new Error('must not read'); } });
  assert.equal(createSessionProjection().read(f.ctx, '1', null).records.length, 2);
});
test('cycles fail closed and clearing drops continuation authority without aborting work', () => {
  const f = fixture(2); f.entries.get('e2').parentId = 'e2';
  assert.throws(() => createSessionProjection().read(f.ctx, '1', null), /ancestry/);
  const good = fixture(70); const projection = createSessionProjection(); const page = projection.read(good.ctx, '1', null);
  projection.clear(); assert.throws(() => projection.read(good.ctx, '1', page.nextLeafId), /handle/);
});
